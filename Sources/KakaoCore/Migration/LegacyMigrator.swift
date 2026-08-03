import CSQLCipher
import CryptoKit
import Foundation

public struct LegacyMigrationReport: Codable, Sendable {
    public let messagesImported: Int
    public let attachmentsBackfilled: Int
    public let mediaCompleteImported: Int
    public let mediaExpiredImported: Int
    public let pendingOutboxSkipped: Int
    public let allowedChatsImported: Int
}

/// One-way, idempotent import from the prior generic SQLite message/outbox
/// layout and the standalone attachment archive. Webhook configuration and
/// outbox payloads are deliberately never migrated.
public final class LegacyMigrator: @unchecked Sendable {
    private let state: StateStore
    private let archiveRoot: URL
    private let sourceDatabase: DatabaseReader?

    public init(state: StateStore, archiveRoot: URL, sourceDatabase: DatabaseReader? = nil) {
        self.state = state
        self.archiveRoot = archiveRoot
        self.sourceDatabase = sourceDatabase
    }

    public func migrate(messagesDatabase: URL, mediaDatabase: URL?, mediaRoot: URL?) throws -> LegacyMigrationReport {
        let messages = try ReadOnlySQLite(path: messagesDatabase.path)
        defer { messages.close() }
        let rows = try messages.messageRows()
        var chats: Set<ChatID> = []
        var backfilled = 0
        for row in rows {
            let chatID = ChatID(rawValue: row.chatID)
            chats.insert(chatID)
            let rawAttachment = try sourceDatabase?.attachmentMetadata(logID: row.logID)
            if rawAttachment != nil { backfilled += 1 }
            try state.importMessage(
                logID: row.logID,
                chatID: chatID,
                timestamp: row.timestamp,
                payload: row.payload,
                rawAttachment: rawAttachment
            )
        }
        for chatID in chats { try state.allow(chatID: chatID) }

        let skipped = try messages.pendingOutboxCount()
        var complete = 0
        var expired = 0
        if let mediaDatabase {
            let media = try ReadOnlySQLite(path: mediaDatabase.path)
            defer { media.close() }
            for row in try media.mediaRows() {
                let rawAttachment = try sourceDatabase?.attachmentMetadata(logID: row.logID)
                try state.importMessage(
                    logID: row.logID,
                    chatID: ChatID(rawValue: row.chatID),
                    timestamp: row.timestamp,
                    payload: Data("{}".utf8),
                    rawAttachment: rawAttachment
                )
                let idSeed = "attachment:\(row.logID):video"
                let id = SHA256.hash(data: Data(idSeed.utf8)).map { String(format: "%02x", $0) }.joined()
                let attachment = NormalizedAttachment(
                    id: id,
                    kind: .video,
                    expectedBytes: row.expectedBytes,
                    checksum: row.sourceSHA1.map { ReportedChecksum(algorithm: "sha1", value: $0) },
                    width: row.width,
                    height: row.height,
                    durationMilliseconds: row.durationSeconds.map { Int64($0) * 1_000 }
                )
                var importedStatus = row.status
                var importedHash = row.sha256
                var importedError = row.error
                if row.status == "complete", let hash = row.sha256 {
                    let source = resolveObject(row: row, mediaRoot: mediaRoot)
                    guard let source, FileManager.default.fileExists(atPath: source.path) else {
                        importedStatus = "unretrievable"
                        importedHash = nil
                        importedError = "Archived object was not found during migration"
                        try state.importAttachmentRecord(
                            id: id, logID: row.logID, attachment: attachment,
                            status: importedStatus, sha256: nil, error: importedError
                        )
                        continue
                    }
                    let data = try Data(contentsOf: source, options: [.mappedIfSafe])
                    let verified = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard verified == hash.lowercased() else {
                        throw KakaoClientError.state("Archived object checksum mismatch for log ID \(row.logID)")
                    }
                    let prefix = String(verified.prefix(2))
                    let directory = archiveRoot.appendingPathComponent("objects/\(prefix)", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    let destination = directory.appendingPathComponent(verified)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try data.write(to: destination, options: [.atomic])
                        _ = chmod(destination.path, 0o600)
                    }
                    let relative = "objects/\(prefix)/\(verified)"
                    try state.registerObject(sha256: verified, bytes: Int64(data.count), relativePath: relative)
                    importedStatus = "complete"
                    importedHash = verified
                    complete += 1
                } else if row.status == "expired" {
                    importedStatus = "expired"
                    expired += 1
                }
                try state.importAttachmentRecord(
                    id: id,
                    logID: row.logID,
                    attachment: attachment,
                    status: importedStatus,
                    sha256: importedHash,
                    error: importedError
                )
            }
        }

        try state.recordMigration(key: "legacy.messages", value: String(rows.count))
        try state.recordMigration(key: "legacy.outbox_skipped", value: String(skipped))
        try state.recordMigration(key: "legacy.webhook_migrated", value: "false")
        return LegacyMigrationReport(
            messagesImported: rows.count,
            attachmentsBackfilled: backfilled,
            mediaCompleteImported: complete,
            mediaExpiredImported: expired,
            pendingOutboxSkipped: skipped,
            allowedChatsImported: chats.count
        )
    }

    private func resolveObject(row: MediaRow, mediaRoot: URL?) -> URL? {
        if let objectPath = row.objectPath, !objectPath.isEmpty {
            return URL(fileURLWithPath: objectPath)
        }
        guard let mediaRoot, let sha256 = row.sha256 else { return nil }
        let exact = mediaRoot.appendingPathComponent("objects/\(sha256)")
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        let mp4 = mediaRoot.appendingPathComponent("objects/\(sha256).mp4")
        return mp4
    }
}

private struct LegacyMessageRow {
    let logID: Int64
    let chatID: Int64
    let timestamp: Date
    let payload: Data
}

private struct MediaRow {
    let logID: Int64
    let chatID: Int64
    let timestamp: Date
    let durationSeconds: Int?
    let width: Int?
    let height: Int?
    let expectedBytes: Int64?
    let sourceSHA1: String?
    let status: String
    let error: String?
    let sha256: String?
    let objectPath: String?
}

private final class ReadOnlySQLite {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw KakaoClientError.state("Could not open migration source \(path)")
        }
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    func messageRows() throws -> [LegacyMessageRow] {
        let formatter = ISO8601DateFormatter()
        return try query("SELECT log_id, chat_id, message_timestamp, payload_json FROM messages ORDER BY log_id") { row in
            let timestamp = row.text(2).flatMap(formatter.date) ?? Date(timeIntervalSince1970: 0)
            return LegacyMessageRow(
                logID: row.int64(0),
                chatID: row.int64(1),
                timestamp: timestamp,
                payload: Data((row.text(3) ?? "{}").utf8)
            )
        }
    }

    func pendingOutboxCount() throws -> Int {
        try query("SELECT count(*) FROM outbox WHERE delivered_at IS NULL") { $0.int(0) }.first ?? 0
    }

    func mediaRows() throws -> [MediaRow] {
        let formatter = ISO8601DateFormatter()
        return try query(
            """
            SELECT log_id, chat_id, sent_at_utc, duration_seconds, width, height,
                   expected_bytes, source_sha1, status, error, sha256, object_path
            FROM archive_items ORDER BY log_id
            """
        ) { row in
            MediaRow(
                logID: row.int64(0),
                chatID: row.int64(1),
                timestamp: row.text(2).flatMap(formatter.date) ?? Date(timeIntervalSince1970: 0),
                durationSeconds: row.optionalInt(3),
                width: row.optionalInt(4),
                height: row.optionalInt(5),
                expectedBytes: row.optionalInt64(6),
                sourceSHA1: row.text(7),
                status: row.text(8) ?? "unretrievable",
                error: row.text(9),
                sha256: row.text(10),
                objectPath: row.text(11)
            )
        }
    }

    private func query<T>(_ sql: String, transform: (Row) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw KakaoClientError.state("Migration SQL prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        var output: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { output.append(transform(Row(statement: statement))) }
            else if result == SQLITE_DONE { return output }
            else { throw KakaoClientError.state("Migration SQL read failed") }
        }
    }

    private struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int(statement, column)) }
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func optionalInt(_ column: Int32) -> Int? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int(column)
        }
        func optionalInt64(_ column: Int32) -> Int64? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int64(column)
        }
        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
    }
}
