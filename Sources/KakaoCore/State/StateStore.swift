import CSQLCipher
import Foundation

public struct StoredSendAttempt: Sendable, Equatable {
    public let destinationKey: String
    public let bodySHA256: String
    public let receipt: SendReceipt
}

public protocol SendStateStoring: AnyObject, Sendable {
    func sendAttempt(requestID: UUID) throws -> StoredSendAttempt?
    func saveSendAttempt(destinationKey: String, bodySHA256: String, receipt: SendReceipt) throws
}

public struct PendingArchiveAttachment: Sendable {
    public let id: String
    public let logID: Int64
    public let attachment: NormalizedAttachment
    public let attempts: Int
}

public struct PendingWebhook: Sendable {
    public let eventID: String
    public let payload: Data
    public let attempts: Int
}

public struct ArchiveAttachmentDelivery: Sendable {
    public let id: String
    public let status: String
    public let sha256: String?
}

/// Encrypted writable state for send idempotency, the allowlisted archive, and
/// the optional webhook outbox.
public final class StateStore: SendStateStoring, @unchecked Sendable {
    private var db: OpaquePointer?
    public let path: String
    public let archiveRoot: String

    public init(path: String, key: String, archiveRoot: String) throws {
        self.path = path
        self.archiveRoot = archiveRoot
        let result = sqlite3_open_v2(
            path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            throw KakaoClientError.state("Could not open encrypted state: \(errorMessage())")
        }
        do {
            guard key.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
                throw KakaoClientError.state("State key has an invalid format")
            }
            try execute("PRAGMA key = \"x'\(key)'\"")
            try execute("PRAGMA cipher_memory_security = ON")
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA busy_timeout = 5000")
            try createSchema()
            _ = chmod(path, 0o600)
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    public func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    public func sendAttempt(requestID: UUID) throws -> StoredSendAttempt? {
        let attempts: [StoredSendAttempt?] = try query(
            """
            SELECT destination, body_sha256, chat_id, log_id, status
            FROM send_attempts WHERE request_id = ? LIMIT 1
            """,
            [.text(requestID.uuidString.lowercased())]
        ) { row in
            guard let status = SendStatus(rawValue: row.text(4) ?? "") else { return nil }
            return StoredSendAttempt(
                destinationKey: row.text(0) ?? "",
                bodySHA256: row.text(1) ?? "",
                receipt: SendReceipt(
                    requestID: requestID,
                    chatID: ChatID(rawValue: row.int64(2)),
                    logID: row.optionalInt64(3),
                    status: status
                )
            )
        }
        return attempts.first.flatMap { $0 }
    }

    public func saveSendAttempt(
        destinationKey: String,
        bodySHA256: String,
        receipt: SendReceipt
    ) throws {
        try run(
            """
            INSERT INTO send_attempts(
                request_id, destination, body_sha256, chat_id, log_id, status, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(request_id) DO NOTHING
            """,
            [
                .text(receipt.requestID.uuidString.lowercased()),
                .text(destinationKey),
                .text(bodySHA256),
                .int64(receipt.chatID.rawValue),
                receipt.logID.map(Value.int64) ?? .null,
                .text(receipt.status.rawValue),
                .double(Date().timeIntervalSince1970),
            ]
        )
    }

    public func allow(chatID: ChatID) throws {
        try run(
            "INSERT INTO allowed_chats(chat_id, added_at) VALUES (?, ?) ON CONFLICT(chat_id) DO NOTHING",
            [.int64(chatID.rawValue), .double(Date().timeIntervalSince1970)]
        )
    }

    public func disallow(chatID: ChatID) throws {
        try run("DELETE FROM allowed_chats WHERE chat_id = ?", [.int64(chatID.rawValue)])
    }

    public func allowedChats() throws -> Set<ChatID> {
        Set(try query("SELECT chat_id FROM allowed_chats ORDER BY chat_id", []) {
            ChatID(rawValue: $0.int64(0))
        })
    }

    @discardableResult
    public func archive(message: Message, attachments: [NormalizedAttachment]) throws -> Bool {
        guard try allowedChats().contains(message.chatId) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let normalized = try encoder.encode(attachments)
        try transaction {
            try run(
                """
                INSERT INTO archive_messages(
                    log_id, chat_id, sender_id, sender_name, text, message_type,
                    sent_at, is_from_me, raw_attachment, normalized_json, archived_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(log_id) DO UPDATE SET
                    chat_id = excluded.chat_id,
                    sender_id = excluded.sender_id,
                    sender_name = excluded.sender_name,
                    text = excluded.text,
                    message_type = excluded.message_type,
                    sent_at = excluded.sent_at,
                    is_from_me = excluded.is_from_me,
                    raw_attachment = COALESCE(excluded.raw_attachment, archive_messages.raw_attachment),
                    normalized_json = excluded.normalized_json
                """,
                [
                    .int64(message.id), .int64(message.chatId.rawValue), .int64(message.senderId),
                    message.senderName.map(Value.text) ?? .null,
                    message.text.map(Value.text) ?? .null,
                    .int(message.type.rawValue), .double(message.createdAt.timeIntervalSince1970),
                    .int(message.isFromMe ? 1 : 0),
                    message.rawAttachment.map { .blob(Data($0.utf8)) } ?? .null,
                    .blob(normalized), .double(Date().timeIntervalSince1970),
                ]
            )
            for attachment in attachments {
                let encoded = try encoder.encode(attachment)
                try run(
                    """
                    INSERT INTO archive_attachments(
                        attachment_id, log_id, kind, metadata_json, status, attempts, updated_at
                    ) VALUES (?, ?, ?, ?, 'pending', 0, ?)
                    ON CONFLICT(attachment_id) DO UPDATE SET metadata_json = excluded.metadata_json
                    """,
                    [
                        .text(attachment.id), .int64(message.id), .text(attachment.kind.rawValue),
                        .blob(encoded), .double(Date().timeIntervalSince1970),
                    ]
                )
            }
        }
        return true
    }

    public func pendingAttachments(limit: Int = 100) throws -> [PendingArchiveAttachment] {
        let decoder = JSONDecoder()
        return try query(
            """
            SELECT attachment_id, log_id, metadata_json, attempts
            FROM archive_attachments
            WHERE status IN ('pending', 'download_failed', 'paused_low_disk')
            ORDER BY updated_at, attachment_id LIMIT ?
            """,
            [.int(max(1, limit))]
        ) { row in
            guard let data = row.blob(2),
                  let attachment = try? decoder.decode(NormalizedAttachment.self, from: data) else {
                return nil
            }
            return PendingArchiveAttachment(
                id: row.text(0) ?? "",
                logID: row.int64(1),
                attachment: attachment,
                attempts: row.int(3)
            )
        }.compactMap { $0 }
    }

    public func updateAttachment(
        id: String,
        status: String,
        sha256: String? = nil,
        error: String? = nil,
        incrementAttempt: Bool = true
    ) throws {
        try run(
            """
            UPDATE archive_attachments
            SET status = ?, sha256 = COALESCE(?, sha256), error = ?,
                attempts = attempts + ?, updated_at = ?
            WHERE attachment_id = ?
            """,
            [
                .text(status), sha256.map(Value.text) ?? .null, error.map(Value.text) ?? .null,
                .int(incrementAttempt ? 1 : 0), .double(Date().timeIntervalSince1970), .text(id),
            ]
        )
    }

    public func attachmentDelivery(logID: Int64) throws -> [ArchiveAttachmentDelivery] {
        try query(
            "SELECT attachment_id, status, sha256 FROM archive_attachments WHERE log_id = ? ORDER BY attachment_id",
            [.int64(logID)]
        ) {
            ArchiveAttachmentDelivery(id: $0.text(0) ?? "", status: $0.text(1) ?? "unknown", sha256: $0.text(2))
        }
    }

    public func registerObject(sha256: String, bytes: Int64, relativePath: String) throws {
        try run(
            """
            INSERT INTO archive_objects(sha256, byte_count, relative_path, created_at)
            VALUES (?, ?, ?, ?) ON CONFLICT(sha256) DO NOTHING
            """,
            [.text(sha256), .int64(bytes), .text(relativePath), .double(Date().timeIntervalSince1970)]
        )
    }

    public func archiveStatus() throws -> ArchiveStatus {
        func count(_ sql: String) throws -> Int {
            try query(sql, []) { $0.int(0) }.first ?? 0
        }
        return ArchiveStatus(
            allowedChatCount: try count("SELECT count(*) FROM allowed_chats"),
            messageCount: try count("SELECT count(*) FROM archive_messages"),
            attachmentCount: try count("SELECT count(*) FROM archive_attachments"),
            objectCount: try count("SELECT count(*) FROM archive_objects"),
            pendingDownloadCount: try count("SELECT count(*) FROM archive_attachments WHERE status IN ('pending', 'download_failed')"),
            pausedLowDiskCount: try count("SELECT count(*) FROM archive_attachments WHERE status = 'paused_low_disk'"),
            expiredAttachmentCount: try count("SELECT count(*) FROM archive_attachments WHERE status = 'expired'"),
            failedDownloadCount: try count("SELECT count(*) FROM archive_attachments WHERE status = 'download_failed'"),
            pendingWebhookCount: try count("SELECT count(*) FROM webhook_outbox WHERE delivered_at IS NULL"),
            archiveRoot: archiveRoot
        )
    }

    public func setConfiguration(key: String, value: String?) throws {
        if let value {
            try run(
                "INSERT INTO configuration(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)]
            )
        } else {
            try run("DELETE FROM configuration WHERE key = ?", [.text(key)])
        }
    }

    public func configuration(key: String) throws -> String? {
        try query("SELECT value FROM configuration WHERE key = ? LIMIT 1", [.text(key)]) {
            $0.text(0)
        }.first.flatMap { $0 }
    }

    public func enqueueWebhook(eventID: String, payload: Data) throws {
        try run(
            """
            INSERT INTO webhook_outbox(event_id, payload_json, attempts, next_attempt_at, created_at)
            VALUES (?, ?, 0, ?, ?) ON CONFLICT(event_id) DO NOTHING
            """,
            [.text(eventID), .blob(payload), .double(Date().timeIntervalSince1970), .double(Date().timeIntervalSince1970)]
        )
    }

    public func pendingWebhooks(limit: Int = 20) throws -> [PendingWebhook] {
        try query(
            """
            SELECT event_id, payload_json, attempts FROM webhook_outbox
            WHERE delivered_at IS NULL AND next_attempt_at <= ?
            ORDER BY created_at LIMIT ?
            """,
            [.double(Date().timeIntervalSince1970), .int(max(1, limit))]
        ) { row in
            PendingWebhook(eventID: row.text(0) ?? "", payload: row.blob(1) ?? Data(), attempts: row.int(2))
        }
    }

    public func markWebhookDelivered(eventID: String) throws {
        try run(
            "UPDATE webhook_outbox SET delivered_at = ?, last_error = NULL WHERE event_id = ?",
            [.double(Date().timeIntervalSince1970), .text(eventID)]
        )
    }

    public func markWebhookFailed(eventID: String, error: String, attempts: Int) throws {
        let delay = min(pow(2.0, Double(attempts)), 3600.0)
        try run(
            """
            UPDATE webhook_outbox SET attempts = attempts + 1, last_error = ?, next_attempt_at = ?
            WHERE event_id = ?
            """,
            [.text(error), .double(Date().addingTimeInterval(delay).timeIntervalSince1970), .text(eventID)]
        )
    }

    /// Import an already archived historical message. The payload remains
    /// encrypted at rest and is not placed in the new webhook outbox.
    public func importMessage(
        logID: Int64,
        chatID: ChatID,
        timestamp: Date,
        payload: Data,
        rawAttachment: String? = nil
    ) throws {
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let senderID = (object?["sender_id"] as? NSNumber)?.int64Value ?? 0
        let senderName = object?["sender"] as? String
        let text = object?["text"] as? String
        let messageType = (object?["message_type"] as? NSNumber)?.intValue ?? -1
        let fromMe = (object?["is_from_me"] as? NSNumber)?.boolValue ?? false
        try run(
            """
            INSERT INTO archive_messages(
                log_id, chat_id, sender_id, sender_name, text, message_type,
                sent_at, is_from_me, raw_attachment, normalized_json, archived_at, legacy_payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
            ON CONFLICT(log_id) DO UPDATE SET
                chat_id = excluded.chat_id,
                sender_id = CASE WHEN excluded.sender_id != 0 THEN excluded.sender_id ELSE archive_messages.sender_id END,
                sender_name = COALESCE(excluded.sender_name, archive_messages.sender_name),
                text = COALESCE(excluded.text, archive_messages.text),
                message_type = CASE WHEN excluded.message_type != -1 THEN excluded.message_type ELSE archive_messages.message_type END,
                sent_at = CASE WHEN excluded.sent_at != 0 THEN excluded.sent_at ELSE archive_messages.sent_at END,
                is_from_me = excluded.is_from_me,
                raw_attachment = COALESCE(excluded.raw_attachment, archive_messages.raw_attachment),
                legacy_payload = COALESCE(archive_messages.legacy_payload, excluded.legacy_payload)
            """,
            [
                .int64(logID), .int64(chatID.rawValue), .int64(senderID),
                senderName.map(Value.text) ?? .null, text.map(Value.text) ?? .null,
                .int(messageType), .double(timestamp.timeIntervalSince1970), .int(fromMe ? 1 : 0),
                rawAttachment.map { .blob(Data($0.utf8)) } ?? .null,
                .double(Date().timeIntervalSince1970), .blob(payload),
            ]
        )
    }

    public func importAttachmentRecord(
        id: String,
        logID: Int64,
        attachment: NormalizedAttachment,
        status: String,
        sha256: String?,
        error: String?
    ) throws {
        let data = try JSONEncoder().encode(attachment)
        try run(
            """
            INSERT INTO archive_attachments(
                attachment_id, log_id, kind, metadata_json, status, attempts,
                sha256, error, updated_at
            ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)
            ON CONFLICT(attachment_id) DO UPDATE SET
                metadata_json = excluded.metadata_json, status = excluded.status,
                sha256 = excluded.sha256, error = excluded.error, updated_at = excluded.updated_at
            """,
            [
                .text(id), .int64(logID), .text(attachment.kind.rawValue), .blob(data), .text(status),
                sha256.map(Value.text) ?? .null, error.map(Value.text) ?? .null,
                .double(Date().timeIntervalSince1970),
            ]
        )
    }

    public func recordMigration(key: String, value: String) throws {
        try run(
            "INSERT INTO migration_audit(key, value, recorded_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, recorded_at = excluded.recorded_at",
            [.text(key), .text(value), .double(Date().timeIntervalSince1970)]
        )
    }

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS send_attempts(
                request_id TEXT PRIMARY KEY,
                destination TEXT NOT NULL,
                body_sha256 TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                log_id INTEGER,
                status TEXT NOT NULL CHECK(status IN ('confirmed', 'unknown')),
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS allowed_chats(
                chat_id INTEGER PRIMARY KEY,
                added_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS archive_messages(
                log_id INTEGER PRIMARY KEY,
                chat_id INTEGER NOT NULL,
                sender_id INTEGER NOT NULL,
                sender_name TEXT,
                text TEXT,
                message_type INTEGER NOT NULL,
                sent_at REAL NOT NULL,
                is_from_me INTEGER NOT NULL,
                raw_attachment BLOB,
                normalized_json BLOB,
                archived_at REAL NOT NULL,
                legacy_payload BLOB
            );
            CREATE INDEX IF NOT EXISTS archive_messages_chat_time
                ON archive_messages(chat_id, sent_at, log_id);
            CREATE TABLE IF NOT EXISTS archive_objects(
                sha256 TEXT PRIMARY KEY,
                byte_count INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS archive_attachments(
                attachment_id TEXT PRIMARY KEY,
                log_id INTEGER NOT NULL REFERENCES archive_messages(log_id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                metadata_json BLOB NOT NULL,
                status TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                sha256 TEXT REFERENCES archive_objects(sha256),
                error TEXT,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS archive_attachments_status
                ON archive_attachments(status, updated_at);
            CREATE TABLE IF NOT EXISTS configuration(
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS webhook_outbox(
                event_id TEXT PRIMARY KEY,
                payload_json BLOB NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at REAL NOT NULL,
                created_at REAL NOT NULL,
                delivered_at REAL,
                last_error TEXT
            );
            CREATE TABLE IF NOT EXISTS migration_audit(
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                recorded_at REAL NOT NULL
            );
            """)
    }

    private enum Value {
        case int(Int)
        case int64(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage()
            sqlite3_free(error)
            throw KakaoClientError.state("State SQL error: \(message)")
        }
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [Value], transform: (Row) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw KakaoClientError.state("State SQL prepare error: \(errorMessage())")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .int(let value): result = sqlite3_bind_int(statement, index, Int32(value))
            case .int64(let value): result = sqlite3_bind_int64(statement, index, value)
            case .double(let value): result = sqlite3_bind_double(statement, index, value)
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
            case .blob(let data):
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.sqliteTransient)
                }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw KakaoClientError.state("State SQL bind error: \(errorMessage())")
            }
        }
        var output: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                output.append(transform(Row(statement: statement)))
            } else if result == SQLITE_DONE {
                return output
            } else {
                throw KakaoClientError.state("State SQL step error: \(errorMessage())")
            }
        }
    }

    private func errorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int(statement, column)) }
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func optionalInt64(_ column: Int32) -> Int64? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int64(column)
        }
        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
        func blob(_ column: Int32) -> Data? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let pointer = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }
}
