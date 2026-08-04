import CSQLCipher
import Foundation

public struct StoredSendAttempt: Sendable, Equatable {
    public let destinationKey: String
    public let bodySHA256: String
    /// Exact bytes are retained only inside the encrypted state database so an
    /// unknown receipt can be reconciled without attempting the UI action again.
    public let body: Data?
    public let highWatermark: Int64?
    public let receipt: SendReceipt
}

public protocol SendStateStoring: AnyObject, Sendable {
    func sendAttempt(requestID: UUID) throws -> StoredSendAttempt?
    func saveSendAttempt(
        destinationKey: String,
        bodySHA256: String,
        body: Data,
        highWatermark: Int64,
        receipt: SendReceipt
    ) throws
    func claimConfirmedSendAttempt(
        destinationKey: String,
        bodySHA256: String,
        body: Data,
        highWatermark: Int64,
        receipt: SendReceipt
    ) throws -> Bool
    func removeSendAttempt(requestID: UUID) throws
}

public struct PendingArchiveAttachment: Sendable {
    public let id: String
    public let logID: Int64
    public let attachment: NormalizedAttachment
    public let attempts: Int
}

public struct ArchivedWebhookRecord: Sendable {
    public let message: Message
    public let attachments: [NormalizedAttachment]
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
    private let mutex = NSRecursiveLock()
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
            try migrateSchema()
            _ = chmod(path, 0o600)
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    public func close() {
        mutex.lock()
        defer { mutex.unlock() }
        if let db { sqlite3_close(db) }
        db = nil
    }

    public func sendAttempt(requestID: UUID) throws -> StoredSendAttempt? {
        mutex.lock()
        defer { mutex.unlock() }
        let attempts: [StoredSendAttempt?] = try query(
            """
            SELECT destination, body_sha256, body, high_watermark, chat_id, log_id, status
            FROM send_attempts WHERE request_id = ? LIMIT 1
            """,
            [.text(requestID.uuidString.lowercased())]
        ) { row in
            guard let status = SendStatus(rawValue: row.text(6) ?? "") else { return nil }
            return StoredSendAttempt(
                destinationKey: row.text(0) ?? "",
                bodySHA256: row.text(1) ?? "",
                body: row.blob(2),
                highWatermark: row.optionalInt64(3),
                receipt: SendReceipt(
                    requestID: requestID,
                    chatID: ChatID(rawValue: row.int64(4)),
                    logID: row.optionalInt64(5),
                    status: status
                )
            )
        }
        return attempts.first.flatMap { $0 }
    }

    public func saveSendAttempt(
        destinationKey: String,
        bodySHA256: String,
        body: Data,
        highWatermark: Int64,
        receipt: SendReceipt
    ) throws {
        guard receipt.status == .unknown, receipt.logID == nil else {
            throw KakaoClientError.state("Confirmed receipts must atomically claim their log ID")
        }
        mutex.lock()
        defer { mutex.unlock() }
        try run(
            """
            INSERT INTO send_attempts(
                request_id, destination, body_sha256, body, high_watermark,
                chat_id, log_id, status, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(request_id) DO UPDATE SET
                body = COALESCE(send_attempts.body, excluded.body),
                high_watermark = COALESCE(send_attempts.high_watermark, excluded.high_watermark),
                chat_id = excluded.chat_id,
                log_id = excluded.log_id,
                status = excluded.status
            WHERE send_attempts.destination = excluded.destination
              AND send_attempts.body_sha256 = excluded.body_sha256
              AND send_attempts.status = 'unknown'
              AND excluded.status = 'confirmed'
            """,
            [
                .text(receipt.requestID.uuidString.lowercased()),
                .text(destinationKey),
                .text(bodySHA256),
                .blob(body),
                .int64(highWatermark),
                .int64(receipt.chatID.rawValue),
                receipt.logID.map(Value.int64) ?? .null,
                .text(receipt.status.rawValue),
                .double(Date().timeIntervalSince1970),
            ]
        )
    }

    /// Atomically upgrades one reserved request to a confirmed receipt only if
    /// no other request ID already owns the same outgoing log row.
    public func claimConfirmedSendAttempt(
        destinationKey: String,
        bodySHA256: String,
        body: Data,
        highWatermark: Int64,
        receipt: SendReceipt
    ) throws -> Bool {
        guard receipt.status == .confirmed, let logID = receipt.logID else {
            throw KakaoClientError.state("A confirmed send claim requires a log ID")
        }
        mutex.lock()
        defer { mutex.unlock() }
        return try transactionValue {
            let requestID = receipt.requestID.uuidString.lowercased()
            let owner = try query(
                "SELECT request_id FROM send_attempts WHERE log_id = ? LIMIT 1",
                [.int64(logID)]
            ) { $0.text(0) ?? "" }.first
            guard owner == nil || owner == requestID else { return false }

            try run(
                """
                UPDATE send_attempts
                SET body = COALESCE(body, ?),
                    high_watermark = COALESCE(high_watermark, ?),
                    chat_id = ?, log_id = ?, status = 'confirmed'
                WHERE request_id = ? AND destination = ? AND body_sha256 = ?
                  AND status = 'unknown'
                """,
                [
                    .blob(body), .int64(highWatermark), .int64(receipt.chatID.rawValue),
                    .int64(logID), .text(requestID), .text(destinationKey), .text(bodySHA256),
                ]
            )
            if sqlite3_changes(db) == 1 { return true }

            // Idempotent success for a receipt this same request already owns.
            return try query(
                """
                SELECT count(*) FROM send_attempts
                WHERE request_id = ? AND destination = ? AND body_sha256 = ?
                  AND chat_id = ? AND log_id = ? AND status = 'confirmed'
                """,
                [
                    .text(requestID), .text(destinationKey), .text(bodySHA256),
                    .int64(receipt.chatID.rawValue), .int64(logID),
                ]
            ) { $0.int(0) }.first == 1
        }
    }

    public func removeSendAttempt(requestID: UUID) throws {
        mutex.lock()
        defer { mutex.unlock() }
        try run(
            "DELETE FROM send_attempts WHERE request_id = ?",
            [.text(requestID.uuidString.lowercased())]
        )
    }

    public func allow(chatID: ChatID, startingAfter logID: Int64 = 0) throws {
        mutex.lock()
        defer { mutex.unlock() }
        try transaction {
        try run(
            "INSERT INTO allowed_chats(chat_id, added_at) VALUES (?, ?) ON CONFLICT(chat_id) DO NOTHING",
            [.int64(chatID.rawValue), .double(Date().timeIntervalSince1970)]
        )
            try run(
                "INSERT INTO archive_checkpoints(chat_id, log_id, updated_at) VALUES (?, ?, ?) ON CONFLICT(chat_id) DO NOTHING",
                [.int64(chatID.rawValue), .int64(max(0, logID)), .double(Date().timeIntervalSince1970)]
            )
        }
    }

    public func disallow(chatID: ChatID) throws {
        mutex.lock()
        defer { mutex.unlock() }
        try run("DELETE FROM allowed_chats WHERE chat_id = ?", [.int64(chatID.rawValue)])
    }

    public func allowedChats() throws -> Set<ChatID> {
        mutex.lock()
        defer { mutex.unlock() }
        return Set(try query("SELECT chat_id FROM allowed_chats ORDER BY chat_id", []) {
            ChatID(rawValue: $0.int64(0))
        })
    }

    public func archiveCheckpoints() throws -> [ChatID: Int64] {
        mutex.lock()
        defer { mutex.unlock() }
        return Dictionary(uniqueKeysWithValues: try query(
            """
            SELECT a.chat_id, COALESCE(c.log_id, 0)
            FROM allowed_chats a
            LEFT JOIN archive_checkpoints c ON c.chat_id = a.chat_id
            ORDER BY a.chat_id
            """,
            []
        ) { (ChatID(rawValue: $0.int64(0)), $0.int64(1)) })
    }

    public func hasArchivedMessage(logID: Int64) throws -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return try query(
            "SELECT 1 FROM archive_messages WHERE log_id = ? LIMIT 1",
            [.int64(logID)]
        ) { _ in true }.first ?? false
    }

    public func archivedWebhookRecord(logID: Int64) throws -> ArchivedWebhookRecord? {
        mutex.lock()
        defer { mutex.unlock() }
        let decoder = JSONDecoder()
        return try query(
            """
            SELECT log_id, chat_id, sender_id, sender_name, text, message_type,
                   sent_at, is_from_me, raw_attachment, normalized_json
            FROM archive_messages WHERE log_id = ? LIMIT 1
            """,
            [.int64(logID)]
        ) { row -> ArchivedWebhookRecord? in
            let attachments = row.blob(9).flatMap {
                try? decoder.decode([NormalizedAttachment].self, from: $0)
            } ?? []
            let rawAttachment = row.blob(8).map { String(decoding: $0, as: UTF8.self) }
            return ArchivedWebhookRecord(
                message: Message(
                    id: row.int64(0),
                    chatId: ChatID(rawValue: row.int64(1)),
                    senderId: row.int64(2),
                    senderName: row.text(3),
                    text: row.text(4),
                    type: Message.MessageType(rawValue: row.int(5)),
                    createdAt: Date(timeIntervalSince1970: row.double(6)),
                    isFromMe: row.int(7) != 0,
                    rawAttachment: rawAttachment
                ),
                attachments: attachments
            )
        }.first.flatMap { $0 }
    }

    public func webhookWasDelivered(eventID: String) throws -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return try query(
            "SELECT delivered_at IS NOT NULL FROM webhook_outbox WHERE event_id = ? LIMIT 1",
            [.text(eventID)]
        ) { $0.int(0) != 0 }.first ?? false
    }

    @discardableResult
    public func archive(message: Message, attachments: [NormalizedAttachment]) throws -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
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

    /// Completes archive ingestion atomically: if webhook delivery is enabled,
    /// the idempotent outbox row is committed in the same transaction as the
    /// per-chat checkpoint. With webhooks disabled, only the checkpoint moves.
    @discardableResult
    public func completeArchiveIngestion(
        chatID: ChatID,
        logID: Int64,
        webhookEventID: String,
        webhookPayload: Data
    ) throws -> Bool {
        guard !webhookEventID.isEmpty, !webhookPayload.isEmpty,
              webhookPayload.count <= KakaoLimits.maximumServicePayloadBytes else {
            throw KakaoClientError.invalidRequest("Webhook outbox payload is invalid or too large")
        }
        mutex.lock()
        defer { mutex.unlock() }
        return try transactionValue {
            let webhookEnabled = try query(
                "SELECT 1 FROM configuration WHERE key = ? LIMIT 1",
                [.text(GenericWebhook.URLKey)]
            ) { _ in true }.first ?? false
            if webhookEnabled {
                try enqueueWebhookRow(eventID: webhookEventID, payload: webhookPayload)
            }
            try advanceArchiveCheckpointRow(chatID: chatID, logID: logID)
            return webhookEnabled
        }
    }

    public func pendingAttachments(limit: Int = 100) throws -> [PendingArchiveAttachment] {
        mutex.lock()
        defer { mutex.unlock() }
        let decoder = JSONDecoder()
        let now = Date().timeIntervalSince1970
        let leaseUntil = now + 10 * 60
        return try transactionValue {
            let decoded: [PendingArchiveAttachment?] = try query(
                """
                SELECT attachment_id, log_id, metadata_json, attempts
                FROM archive_attachments
                WHERE status IN ('pending', 'download_failed', 'paused_low_disk')
                  AND next_attempt_at <= ?
                  AND (lease_until IS NULL OR lease_until < ?)
                ORDER BY next_attempt_at, updated_at, attachment_id LIMIT ?
                """,
                [.double(now), .double(now), .int(max(1, min(limit, 100)))]
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
            }
            let values = decoded.compactMap { $0 }
            for value in values {
                try run(
                    "UPDATE archive_attachments SET lease_until = ? WHERE attachment_id = ?",
                    [.double(leaseUntil), .text(value.id)]
                )
            }
            return values
        }
    }

    public func updateAttachment(
        id: String,
        status: String,
        sha256: String? = nil,
        error: String? = nil,
        incrementAttempt: Bool = true,
        retryAt: Date? = nil
    ) throws {
        mutex.lock()
        defer { mutex.unlock() }
        try run(
            """
            UPDATE archive_attachments
            SET status = ?, sha256 = COALESCE(?, sha256), error = ?,
                attempts = attempts + ?, updated_at = ?, next_attempt_at = ?, lease_until = NULL
            WHERE attachment_id = ?
            """,
            [
                .text(status), sha256.map(Value.text) ?? .null, error.map(Value.text) ?? .null,
                .int(incrementAttempt ? 1 : 0), .double(Date().timeIntervalSince1970),
                .double((retryAt ?? Date()).timeIntervalSince1970), .text(id),
            ]
        )
    }

    public func attachmentDelivery(logID: Int64) throws -> [ArchiveAttachmentDelivery] {
        mutex.lock()
        defer { mutex.unlock() }
        return try query(
            "SELECT attachment_id, status, sha256 FROM archive_attachments WHERE log_id = ? ORDER BY attachment_id",
            [.int64(logID)]
        ) {
            ArchiveAttachmentDelivery(id: $0.text(0) ?? "", status: $0.text(1) ?? "unknown", sha256: $0.text(2))
        }
    }

    public func registerObject(sha256: String, bytes: Int64, relativePath: String) throws {
        mutex.lock()
        defer { mutex.unlock() }
        try run(
            """
            INSERT INTO archive_objects(sha256, byte_count, relative_path, created_at)
            VALUES (?, ?, ?, ?) ON CONFLICT(sha256) DO NOTHING
            """,
            [.text(sha256), .int64(bytes), .text(relativePath), .double(Date().timeIntervalSince1970)]
        )
    }

    public func archiveStatus() throws -> ArchiveStatus {
        mutex.lock()
        defer { mutex.unlock() }
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
            failedDownloadCount: try count("SELECT count(*) FROM archive_attachments WHERE status IN ('download_failed', 'verification_failed', 'too_large', 'unretrievable')"),
            pendingWebhookCount: try count("SELECT count(*) FROM webhook_outbox WHERE delivered_at IS NULL"),
            archiveRoot: archiveRoot
        )
    }

    public func setConfiguration(key: String, value: String?) throws {
        mutex.lock()
        defer { mutex.unlock() }
        if let value {
            try run(
                "INSERT INTO configuration(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)]
            )
        } else {
            try run("DELETE FROM configuration WHERE key = ?", [.text(key)])
        }
    }

    public func configureWebhook(url: String?, bearerToken: String?) throws {
        mutex.lock()
        defer { mutex.unlock() }
        try transaction {
            if let url {
                // The endpoint is the enable bit. Store the optional secret
                // first, then publish the URL, all in one transaction.
                try setConfigurationRow(key: GenericWebhook.bearerKey, value: bearerToken)
                try setConfigurationRow(key: GenericWebhook.URLKey, value: url)
            } else {
                // Disable first so even future schema changes preserve the
                // fail-closed ordering inside this atomic transaction.
                try setConfigurationRow(key: GenericWebhook.URLKey, value: nil)
                try setConfigurationRow(key: GenericWebhook.bearerKey, value: nil)
            }
        }
    }

    public func configuration(key: String) throws -> String? {
        mutex.lock()
        defer { mutex.unlock() }
        return try query("SELECT value FROM configuration WHERE key = ? LIMIT 1", [.text(key)]) {
            $0.text(0)
        }.first.flatMap { $0 }
    }

    public func webhookConfiguration() throws -> (url: String, bearerToken: String?)? {
        mutex.lock()
        defer { mutex.unlock() }
        let rows: [(String?, String?)] = try query(
            """
            SELECT MAX(CASE WHEN key = ? THEN value END),
                   MAX(CASE WHEN key = ? THEN value END)
            FROM configuration WHERE key IN (?, ?)
            """,
            [
                .text(GenericWebhook.URLKey), .text(GenericWebhook.bearerKey),
                .text(GenericWebhook.URLKey), .text(GenericWebhook.bearerKey),
            ]
        ) { ($0.text(0), $0.text(1)) }
        guard let row = rows.first, let url = row.0 else { return nil }
        return (url, row.1)
    }

    public func enqueueWebhook(eventID: String, payload: Data) throws {
        mutex.lock()
        defer { mutex.unlock() }
        try enqueueWebhookRow(eventID: eventID, payload: payload)
    }

    private func enqueueWebhookRow(eventID: String, payload: Data) throws {
        try run(
            """
            INSERT INTO webhook_outbox(event_id, payload_json, attempts, next_attempt_at, created_at)
            VALUES (?, ?, 0, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET payload_json = excluded.payload_json
            WHERE webhook_outbox.delivered_at IS NULL
            """,
            [.text(eventID), .blob(payload), .double(Date().timeIntervalSince1970), .double(Date().timeIntervalSince1970)]
        )
    }

    private func advanceArchiveCheckpointRow(chatID: ChatID, logID: Int64) throws {
        try run(
            """
            INSERT INTO archive_checkpoints(chat_id, log_id, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(chat_id) DO UPDATE SET
                log_id = MAX(archive_checkpoints.log_id, excluded.log_id),
                updated_at = excluded.updated_at
            """,
            [.int64(chatID.rawValue), .int64(logID), .double(Date().timeIntervalSince1970)]
        )
    }

    private func setConfigurationRow(key: String, value: String?) throws {
        if let value {
            try run(
                "INSERT INTO configuration(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)]
            )
        } else {
            try run("DELETE FROM configuration WHERE key = ?", [.text(key)])
        }
    }

    public func pendingWebhooks(limit: Int = 20) throws -> [PendingWebhook] {
        mutex.lock()
        defer { mutex.unlock() }
        let now = Date().timeIntervalSince1970
        return try transactionValue {
            let values = try query(
                """
                SELECT event_id, payload_json, attempts FROM webhook_outbox
                WHERE delivered_at IS NULL AND next_attempt_at <= ?
                  AND (lease_until IS NULL OR lease_until < ?)
                ORDER BY created_at LIMIT ?
                """,
                [.double(now), .double(now), .int(max(1, min(limit, 100)))]
            ) { row in
                PendingWebhook(eventID: row.text(0) ?? "", payload: row.blob(1) ?? Data(), attempts: row.int(2))
            }
            for value in values {
                try run(
                    "UPDATE webhook_outbox SET lease_until = ? WHERE event_id = ?",
                    [.double(now + 60), .text(value.eventID)]
                )
            }
            return values
        }
    }

    public func markWebhookDelivered(eventID: String) throws {
        mutex.lock()
        defer { mutex.unlock() }
        try run(
            "UPDATE webhook_outbox SET delivered_at = ?, last_error = NULL, lease_until = NULL WHERE event_id = ?",
            [.double(Date().timeIntervalSince1970), .text(eventID)]
        )
    }

    public func markWebhookFailed(eventID: String, error: String, attempts: Int) throws {
        mutex.lock()
        defer { mutex.unlock() }
        let delay = min(pow(2.0, Double(attempts)), 3600.0)
        try run(
            """
            UPDATE webhook_outbox SET attempts = attempts + 1, last_error = ?, next_attempt_at = ?, lease_until = NULL
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
        mutex.lock()
        defer { mutex.unlock() }
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let senderID = (object?["sender_id"] as? NSNumber)?.int64Value ?? 0
        let senderName = object?["sender"] as? String
        let text = object?["text"] as? String
        let messageType = (object?["message_type"] as? NSNumber)?.intValue ?? -1
        let parsedFromMe = (object?["is_from_me"] as? NSNumber)?.boolValue
        let fromMe = parsedFromMe ?? false
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
                is_from_me = CASE WHEN ? != 0 THEN excluded.is_from_me ELSE archive_messages.is_from_me END,
                raw_attachment = COALESCE(excluded.raw_attachment, archive_messages.raw_attachment),
                legacy_payload = COALESCE(archive_messages.legacy_payload, excluded.legacy_payload)
            """,
            [
                .int64(logID), .int64(chatID.rawValue), .int64(senderID),
                senderName.map(Value.text) ?? .null, text.map(Value.text) ?? .null,
                .int(messageType), .double(timestamp.timeIntervalSince1970), .int(fromMe ? 1 : 0),
                rawAttachment.map { .blob(Data($0.utf8)) } ?? .null,
                .double(Date().timeIntervalSince1970), .blob(payload),
                .int(parsedFromMe == nil ? 0 : 1),
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
        mutex.lock()
        defer { mutex.unlock() }
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
        mutex.lock()
        defer { mutex.unlock() }
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
                body BLOB,
                high_watermark INTEGER,
                chat_id INTEGER NOT NULL,
                log_id INTEGER,
                status TEXT NOT NULL CHECK(status IN ('confirmed', 'unknown')),
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS allowed_chats(
                chat_id INTEGER PRIMARY KEY,
                added_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS archive_checkpoints(
                chat_id INTEGER PRIMARY KEY REFERENCES allowed_chats(chat_id) ON DELETE CASCADE,
                log_id INTEGER NOT NULL,
                updated_at REAL NOT NULL
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
                next_attempt_at REAL NOT NULL DEFAULT 0,
                lease_until REAL,
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
                last_error TEXT,
                lease_until REAL
            );
            CREATE TABLE IF NOT EXISTS migration_audit(
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                recorded_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS webhook_outbox_pending
                ON webhook_outbox(next_attempt_at, created_at)
                WHERE delivered_at IS NULL;
            """)
    }

    /// Additive migrations keep already-encrypted v1 state usable in place.
    private func migrateSchema() throws {
        if try !hasColumn(table: "send_attempts", name: "body") {
            try execute("ALTER TABLE send_attempts ADD COLUMN body BLOB")
        }
        if try !hasColumn(table: "send_attempts", name: "high_watermark") {
            try execute("ALTER TABLE send_attempts ADD COLUMN high_watermark INTEGER")
        }
        if try !hasColumn(table: "archive_attachments", name: "next_attempt_at") {
            try execute("ALTER TABLE archive_attachments ADD COLUMN next_attempt_at REAL NOT NULL DEFAULT 0")
        }
        if try !hasColumn(table: "archive_attachments", name: "lease_until") {
            try execute("ALTER TABLE archive_attachments ADD COLUMN lease_until REAL")
        }
        if try !hasColumn(table: "webhook_outbox", name: "lease_until") {
            try execute("ALTER TABLE webhook_outbox ADD COLUMN lease_until REAL")
        }
        // Older state databases did not enforce exclusive confirmed-log
        // ownership. Preserve the earliest owner and fail closed for any
        // duplicate historical claims before adding the durable constraint.
        try execute(
            """
            UPDATE send_attempts
            SET log_id = NULL, status = 'unknown'
            WHERE rowid IN (
                SELECT duplicate.rowid
                FROM send_attempts AS duplicate
                JOIN (
                    SELECT log_id, MIN(rowid) AS owner_rowid
                    FROM send_attempts
                    WHERE log_id IS NOT NULL
                    GROUP BY log_id
                    HAVING COUNT(*) > 1
                ) AS collision ON collision.log_id = duplicate.log_id
                WHERE duplicate.rowid != collision.owner_rowid
            )
            """
        )
        try execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS send_attempts_log_id_unique
            ON send_attempts(log_id) WHERE log_id IS NOT NULL
            """
        )
        try execute(
            """
            INSERT INTO archive_checkpoints(chat_id, log_id, updated_at)
            SELECT a.chat_id, COALESCE(MAX(m.log_id), 0), strftime('%s','now')
            FROM allowed_chats a
            LEFT JOIN archive_messages m ON m.chat_id = a.chat_id
            GROUP BY a.chat_id
            ON CONFLICT(chat_id) DO NOTHING
            """
        )
    }

    private func hasColumn(table: String, name: String) throws -> Bool {
        try query("PRAGMA table_info(\(table))", []) { $0.text(1) ?? "" }.contains(name)
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

    private func transactionValue<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
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
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
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
