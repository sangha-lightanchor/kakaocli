import CSQLCipher
import Foundation

public protocol KakaoDatabaseAccess: AnyObject, Sendable {
    func chats(limit: Int) throws -> [Chat]
    func chat(id: ChatID) throws -> Chat?
    func selfChat() throws -> Chat?
    func messages(chatID: ChatID?, since: Date?, limit: Int) throws -> [Message]
    func maxLogID(chatID: ChatID?) throws -> Int64
    func messagesSince(logID: Int64, limit: Int) throws -> [Message]
    func confirmedOutgoing(chatID: ChatID, body: Data, after logID: Int64) throws -> Int64?
    func attachmentMetadata(logID: Int64) throws -> String?
}

/// A persistent, read-only SQLCipher connection to KakaoTalk's local database.
/// Callers serialize access through `KakaoClient`.
public final class DatabaseReader: KakaoDatabaseAccess, @unchecked Sendable {
    private var db: OpaquePointer?
    private var chatIndex: [ChatID: Chat] = [:]
    public let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    deinit { close() }

    public func open(key: String? = nil) throws {
        close()
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw KakaoError.databaseNotFound(databasePath)
        }

        let result = sqlite3_open_v2(
            databasePath,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            throw KakaoError.databaseOpenFailed(errorMessage())
        }

        if let key {
            var opened = false
            for compatibility in [3, 4] {
                do {
                    try execute("PRAGMA cipher_default_compatibility = \(compatibility)")
                    try execute("PRAGMA key = '\(Self.escapeSQLLiteral(key))'")
                    try execute("SELECT count(*) FROM sqlite_master")
                    opened = true
                    break
                } catch {
                    continue
                }
            }
            guard opened else {
                close()
                throw KakaoError.databaseOpenFailed("The SQLCipher key did not open the KakaoTalk database")
            }
        } else {
            try execute("SELECT count(*) FROM sqlite_master")
        }
    }

    public func tryOpen(key: String) -> Bool {
        do {
            try open(key: key)
            return true
        } catch {
            close()
            return false
        }
    }

    public func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    public func chats(limit: Int = 50) throws -> [Chat] {
        let selfDisplayName = try currentUserDisplayName()
        let sql = """
            SELECT r.chatId, r.type, r.chatName, r.activeMembersCount,
                   r.lastLogId, r.lastUpdatedAt, r.countOfNewMessage,
                   u.displayName, u.friendNickName, u.nickName,
                   (SELECT cm.groupNickname FROM NTChatMeta cm
                    WHERE cm.chatId = r.chatId AND cm.type = 3 LIMIT 1),
                   (SELECT cm.content FROM NTChatMeta cm
                    WHERE cm.chatId = r.chatId AND cm.type = 3 LIMIT 1),
                   r.displayMemberIds
            FROM NTChatRoom r
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            ORDER BY r.lastUpdatedAt DESC
            LIMIT ?
            """

        struct Record {
            let chat: Chat
            let memberIDs: [Int64]
        }

        let records: [Record] = try query(sql, bindings: [.int(max(1, limit))]) { row in
            let rawType = row.int(1)
            let type = Chat.ChatType.from(rawInt: rawType)
            let explicitName = [row.string(2), row.string(10), row.string(11)]
                .compactMap(Self.nonEmpty)
                .first
            let directName = [row.string(8), row.string(7), row.string(9)]
                .compactMap(Self.nonEmpty)
                .first
            let isSelf = type == .selfChat
            // KakaoTalk labels the self row as "My Chat"/"나와의 채팅", but
            // titles the opened room with the current user's display name.
            // Resolve that title from the same local database so the sender can
            // verify the newly opened window without trusting a generic label.
            let name = isSelf ? (selfDisplayName ?? "(unknown)") : (explicitName ?? directName ?? "(unknown)")
            return Record(
                chat: Chat(
                    id: ChatID(rawValue: row.int64(0)),
                    type: type,
                    displayName: name,
                    memberCount: row.int(3),
                    lastMessageId: row.optionalInt64(4),
                    lastMessageAt: row.optionalKakaoDate(5),
                    unreadCount: row.int(6),
                    isSelfChat: isSelf
                ),
                memberIDs: row.data(12).map(Self.decodeMemberIDs) ?? []
            )
        }

        let unresolvedIDs = Set(records
            .filter { $0.chat.displayName == "(unknown)" }
            .flatMap(\.memberIDs))
        let names = try displayNames(for: unresolvedIDs)

        let resolved = records.map { record in
            guard record.chat.displayName == "(unknown)" else { return record.chat }
            let resolved = record.memberIDs
                .compactMap { names[$0] }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard !resolved.isEmpty else { return record.chat }
            return Chat(
                id: record.chat.id,
                type: record.chat.type,
                displayName: resolved.joined(separator: ", "),
                memberCount: record.chat.memberCount,
                lastMessageId: record.chat.lastMessageId,
                lastMessageAt: record.chat.lastMessageAt,
                unreadCount: record.chat.unreadCount,
                isSelfChat: record.chat.isSelfChat
            )
        }
        chatIndex.removeAll(keepingCapacity: true)
        for chat in resolved { chatIndex[chat.id] = chat }
        return resolved
    }

    public func chat(id: ChatID) throws -> Chat? {
        if let cached = chatIndex[id] { return cached }
        return try chats(limit: 1_000_000).first { $0.id == id }
    }

    public func selfChat() throws -> Chat? {
        if let cached = chatIndex.values.first(where: \.isSelfChat) { return cached }
        return try chats(limit: 1_000_000).first(where: \.isSelfChat)
    }

    public func messages(
        chatID: ChatID? = nil,
        since: Date? = nil,
        limit: Int = 50
    ) throws -> [Message] {
        var conditions: [String] = []
        var bindings: [SQLValue] = []
        if let chatID {
            conditions.append("m.chatId = ?")
            bindings.append(.int64(chatID.rawValue))
        }
        if let since {
            conditions.append("m.sentAt >= ?")
            bindings.append(.int64(Int64(since.timeIntervalSince1970)))
        }
        let clause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT m.logId, m.chatId, m.authorId,
                   COALESCE(u.displayName, u.friendNickName, u.nickName),
                   m.message, m.type, m.sentAt, m.attachment
            FROM NTChatMessage m
            LEFT JOIN NTUser u ON m.authorId = u.userId AND u.linkId = 0
            \(clause)
            ORDER BY m.sentAt DESC, m.logId DESC
            LIMIT ?
            """
        bindings.append(.int(max(1, limit)))
        let ownID = try myUserID()
        return try query(sql, bindings: bindings) { row in
            Self.makeMessage(row: row, ownID: ownID)
        }
    }

    public func maxLogID(chatID: ChatID? = nil) throws -> Int64 {
        let sql: String
        let bindings: [SQLValue]
        if let chatID {
            sql = "SELECT MAX(logId) FROM NTChatMessage WHERE chatId = ?"
            bindings = [.int64(chatID.rawValue)]
        } else {
            sql = "SELECT MAX(logId) FROM NTChatMessage"
            bindings = []
        }
        return try query(sql, bindings: bindings) { $0.optionalInt64(0) }.first.flatMap { $0 } ?? 0
    }

    public func messagesSince(logID: Int64, limit: Int = 500) throws -> [Message] {
        let sql = """
            SELECT m.logId, m.chatId, m.authorId,
                   COALESCE(u.displayName, u.friendNickName, u.nickName),
                   m.message, m.type, m.sentAt, m.attachment
            FROM NTChatMessage m
            LEFT JOIN NTUser u ON m.authorId = u.userId AND u.linkId = 0
            WHERE m.logId > ?
            ORDER BY m.logId ASC
            LIMIT ?
            """
        let ownID = try myUserID()
        return try query(sql, bindings: [.int64(logID), .int(max(1, limit))]) {
            Self.makeMessage(row: $0, ownID: ownID)
        }
    }

    /// Confirm only a new outgoing row in the intended chat whose message bytes
    /// exactly match the caller's UTF-8 payload.
    public func confirmedOutgoing(chatID: ChatID, body: Data, after logID: Int64) throws -> Int64? {
        let sql = """
            SELECT m.logId
            FROM NTChatMessage m
            WHERE m.chatId = ? AND m.logId > ? AND m.authorId = ?
              AND CAST(m.message AS BLOB) = ?
            ORDER BY m.logId ASC
            LIMIT 1
            """
        return try query(
            sql,
            bindings: [.int64(chatID.rawValue), .int64(logID), .int64(try myUserID()), .blob(body)]
        ) { $0.int64(0) }.first
    }

    public func attachmentMetadata(logID: Int64) throws -> String? {
        try query(
            "SELECT attachment FROM NTChatMessage WHERE logId = ? LIMIT 1",
            bindings: [.int64(logID)]
        ) { $0.string(0) }.first.flatMap { $0 }
    }

    public func myUserID() throws -> Int64 {
        try query("SELECT userId FROM NTChatContext LIMIT 1", bindings: []) { $0.int64(0) }.first ?? 0
    }

    public func schema() throws -> [(name: String, sql: String)] {
        try query(
            "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name",
            bindings: []
        ) { ($0.string(0) ?? "", $0.string(1) ?? "") }
    }

    static func decodeMemberIDs(_ data: Data) -> [Int64] {
        guard let values = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [NSNumber] else { return [] }
        return values.map(\.int64Value)
    }

    private func displayNames(for ids: Set<Int64>) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let values = ids.sorted()
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
        let rows: [(Int64, String)] = try query(
            """
            SELECT userId, COALESCE(NULLIF(friendNickName, ''), NULLIF(displayName, ''), NULLIF(nickName, ''))
            FROM NTUser WHERE linkId = 0 AND userId IN (\(placeholders))
            """,
            bindings: values.map(SQLValue.int64)
        ) { ($0.int64(0), $0.string(1) ?? "") }
        return Dictionary(uniqueKeysWithValues: rows.filter { !$0.1.isEmpty })
    }

    private func currentUserDisplayName() throws -> String? {
        try query(
            """
            SELECT COALESCE(NULLIF(u.displayName, ''), NULLIF(u.nickName, ''), NULLIF(u.friendNickName, ''))
            FROM NTChatContext c
            JOIN NTUser u ON u.userId = c.userId AND u.linkId = 0
            LIMIT 1
            """,
            bindings: []
        ) { Self.nonEmpty($0.string(0)) }.first.flatMap { $0 }
    }

    private static func makeMessage(row: Row, ownID: Int64) -> Message {
        Message(
            id: row.int64(0),
            chatId: ChatID(rawValue: row.int64(1)),
            senderId: row.int64(2),
            senderName: row.string(3),
            text: row.string(4),
            type: Message.MessageType(rawValue: row.int(5)),
            createdAt: row.kakaoDate(6),
            isFromMe: row.int64(2) == ownID,
            rawAttachment: row.string(7)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func escapeSQLLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private enum SQLValue {
        case int(Int)
        case int64(Int64)
        case string(String)
        case blob(Data)
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage()
            sqlite3_free(error)
            throw KakaoError.sqlError(message)
        }
    }

    private func query<T>(
        _ sql: String,
        bindings: [SQLValue],
        transform: (Row) -> T
    ) throws -> [T] {
        guard db != nil else { throw KakaoError.databaseOpenFailed("Database is not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw KakaoError.sqlError("prepare: \(errorMessage())")
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .int(let value): result = sqlite3_bind_int(statement, index, Int32(value))
            case .int64(let value): result = sqlite3_bind_int64(statement, index, value)
            case .string(let value):
                result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), Self.sqliteTransient)
                }
            }
            guard result == SQLITE_OK else { throw KakaoError.sqlError("bind: \(errorMessage())") }
        }

        var output: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                output.append(transform(Row(statement: statement)))
            } else if step == SQLITE_DONE {
                return output
            } else {
                throw KakaoError.sqlError("step: \(errorMessage())")
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
        func string(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
        func data(_ column: Int32) -> Data? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let pointer = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        }
        func kakaoDate(_ column: Int32) -> Date {
            Date(timeIntervalSince1970: Double(int64(column)))
        }
        func optionalKakaoDate(_ column: Int32) -> Date? {
            let value = int64(column)
            return value == 0 ? nil : Date(timeIntervalSince1970: Double(value))
        }
    }
}
