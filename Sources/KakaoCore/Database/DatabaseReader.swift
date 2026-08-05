import CSQLCipher
import Darwin
import Foundation

/// Reads KakaoTalk's encrypted SQLite database using SQLCipher.
public final class DatabaseReader: @unchecked Sendable {
    private var db: OpaquePointer?
    private let metadataStore: MetadataStore?
    public let databasePath: String

    public init(databasePath: String, metadataStore: MetadataStore? = nil) {
        self.databasePath = databasePath
        self.metadataStore = metadataStore
    }

    deinit {
        close()
    }

    /// Open the database. If a key is provided, uses SQLCipher's typed key API.
    /// Tries cipher compatibility modes 3 and 4 (for newer KakaoTalk versions).
    public func open(key: String? = nil) throws {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw KakaoError.databaseNotFound(databasePath)
        }
        var databaseMetadata = stat()
        guard lstat(databasePath, &databaseMetadata) == 0,
              databaseMetadata.st_mode & S_IFMT == S_IFREG,
              databaseMetadata.st_uid == geteuid() else {
            throw KakaoError.databaseOpenFailed(
                "Database must be a user-owned regular file, not a symbolic link"
            )
        }

        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX

        if let key {
            guard !key.isEmpty else {
                throw KakaoError.databaseOpenFailed("SQLCipher key cannot be empty")
            }
            // Try compatibility mode 3 first (legacy), then 4 (newer versions)
            let compatModes = [3, 4]
            for compat in compatModes {
                // Close previous attempt if any
                if db != nil { sqlite3_close(db); db = nil }

                let result = sqlite3_open_v2(
                    databasePath, &db,
                    openFlags, nil
                )
                guard result == SQLITE_OK else {
                    let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                    throw KakaoError.databaseOpenFailed(msg)
                }

                do {
                    try exec("PRAGMA cipher_default_compatibility = \(compat)")
                    let keyResult = Data(key.utf8).withUnsafeBytes { bytes in
                        sqlite3_key(db, bytes.baseAddress, Int32(bytes.count))
                    }
                    guard keyResult == SQLITE_OK else {
                        throw KakaoError.databaseOpenFailed("sqlite3_key rejected the key")
                    }
                    try exec("SELECT count(*) FROM sqlite_master")
                    try exec("PRAGMA query_only = ON")
                    return // success
                } catch {
                    continue
                }
            }
            close()
            throw KakaoError.databaseOpenFailed(
                "SQLCipher keying failed with all compatibility modes — " +
                "database is encrypted and key may be wrong, or SQLCipher may not be linked. " +
                "Install via: brew install sqlcipher"
            )
        } else {
            let result = sqlite3_open_v2(
                databasePath, &db,
                openFlags, nil
            )
            guard result == SQLITE_OK else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw KakaoError.databaseOpenFailed(msg)
            }
            try exec("PRAGMA query_only = ON")
        }
    }

    /// Try opening the database with a key. Returns true if the key is valid.
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
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Queries

    /// List all chat rooms.
    public func chats(limit: Int = 50) throws -> [Chat] {
        try loadChats(chatId: nil, selfOnly: false, limit: max(1, limit))
    }

    /// Resolve send identities with fresh source-database queries. The UI has
    /// only a display label, so the caller separately requires that label to
    /// map to exactly one current database chat.
    public func chat(id: Int64) throws -> Chat? {
        try loadChats(chatId: id, selfOnly: false, limit: nil).first
    }

    public func selfChat() throws -> Chat? {
        let matches = try loadChats(chatId: nil, selfOnly: true, limit: nil)
        guard matches.count <= 1 else {
            throw KakaoError.databaseOpenFailed("The self-chat identity is ambiguous")
        }
        return matches.first
    }

    public func chatUIIdentityCount(displayName: String) throws -> Int {
        try loadChats(chatId: nil, selfOnly: false, limit: nil)
            .count { $0.displayName == displayName }
    }

    private func loadChats(chatId: Int64?, selfOnly: Bool, limit: Int?) throws -> [Chat] {
        let selfDisplayName = try currentUserDisplayName()
        var conditions: [String] = []
        var bindings: [SQLValue] = []
        if let chatId {
            conditions.append("r.chatId = ?")
            bindings.append(.int64(chatId))
        }
        if selfOnly { conditions.append("r.type = 5") }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let limitClause = limit == nil ? "" : "LIMIT ?"
        let sql = """
            SELECT r.chatId, r.type, r.chatName, r.activeMembersCount,
                   r.lastLogId, r.lastUpdatedAt, r.countOfNewMessage,
                   u.displayName, u.friendNickName, u.nickName,
                   r.displayMemberIds
            FROM NTChatRoom r
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            \(whereClause)
            ORDER BY r.lastUpdatedAt DESC
            \(limitClause)
            """
        if let limit { bindings.append(.int(max(1, limit))) }
        let loaded = try query(sql, bind: bindings) { row in
            // For direct chats, use the friend's name; for groups, use chatName
            let chatName = Self.nonempty(row.string(2))
            // Kakao's chat list prefers the locally assigned friend nickname.
            let displayName = Self.nonempty(row.string(8))
                ?? Self.nonempty(row.string(7))
                ?? Self.nonempty(row.string(9))
            let isSelf = row.int(1) == 5
            let name = isSelf ? (selfDisplayName ?? "(unknown)") : (chatName ?? displayName ?? "(unknown)")

            return LoadedChat(
                id: row.int64(0),
                rawType: row.int(1),
                displayName: name,
                memberCount: row.int(3),
                lastMessageId: row.optionalInt64(4),
                lastMessageAt: row.optionalKakaoDate(5),
                unreadCount: row.int(6),
                isSelfChat: isSelf,
                displayMemberIDs: row.data(10)
            )
        }
        return try loaded.map { value in
            let verifiedGroupName: String?
            if value.rawType == 1, value.displayName == "(unknown)" {
                verifiedGroupName = try participantVerifiedGroupName(
                    chatID: value.id,
                    memberCount: value.memberCount,
                    displayMemberIDs: value.displayMemberIDs
                )
            } else {
                verifiedGroupName = nil
            }
            return Chat(
                id: value.id,
                type: Chat.ChatType.from(rawInt: value.rawType),
                displayName: verifiedGroupName ?? value.displayName,
                memberCount: value.memberCount,
                lastMessageId: value.lastMessageId,
                lastMessageAt: value.lastMessageAt,
                unreadCount: value.unreadCount,
                isSelfChat: value.isSelfChat
            )
        }
    }

    /// Kakao leaves `chatName` empty for participant-named group rooms. Use a
    /// harvested UI title only when fresh source-database membership proves the
    /// same complete participant-name multiset and member count. The UI layer
    /// still has to find exactly one row/window with this exact title.
    private func participantVerifiedGroupName(
        chatID: Int64,
        memberCount: Int,
        displayMemberIDs: Data?
    ) throws -> String? {
        guard let metadataStore,
              let metadata = metadataStore.info(for: chatID),
              metadata.chatType == 1,
              metadata.memberCount == memberCount,
              metadata.lastHarvested != nil,
              let displayMemberIDs,
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: displayMemberIDs,
                  options: [],
                  format: nil
              ),
              let values = propertyList as? [Any] else { return nil }

        let memberIDs = values.compactMap { value -> Int64? in
            if let number = value as? NSNumber { return number.int64Value }
            if let integer = value as? Int { return Int64(integer) }
            if let integer = value as? Int64 { return integer }
            return nil
        }
        guard memberCount > 1,
              memberIDs.count == values.count,
              memberIDs.count == memberCount - 1,
              memberIDs.allSatisfy({ $0 > 0 }),
              Set(memberIDs).count == memberIDs.count else { return nil }

        let placeholders = Array(repeating: "?", count: memberIDs.count)
            .joined(separator: ",")
        let rows = try query(
            """
            SELECT userId,
                   COALESCE(NULLIF(friendNickName, ''), NULLIF(displayName, ''), NULLIF(nickName, ''))
            FROM NTUser
            WHERE linkId = 0 AND userId IN (\(placeholders))
            """,
            bind: memberIDs.map(SQLValue.int64)
        ) { row in
            (row.int64(0), Self.nonempty(row.string(1)))
        }
        guard rows.count == memberIDs.count else { return nil }
        var namesByID: [Int64: String] = [:]
        for (id, name) in rows {
            guard let name, namesByID[id] == nil else { return nil }
            namesByID[id] = name
        }
        guard namesByID.count == memberIDs.count else { return nil }
        let currentNames = memberIDs.compactMap { namesByID[$0] }
        guard currentNames.count == memberIDs.count else { return nil }

        let harvestedName = metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !harvestedName.isEmpty, harvestedName != "(unknown)" else { return nil }
        let harvestedNames = harvestedName.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard harvestedNames.allSatisfy({ !$0.isEmpty }),
              Self.multiset(harvestedNames) == Self.multiset(currentNames) else { return nil }
        return harvestedName
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func multiset(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { counts, value in counts[value, default: 0] += 1 }
    }

    private struct LoadedChat {
        let id: Int64
        let rawType: Int
        let displayName: String
        let memberCount: Int
        let lastMessageId: Int64?
        let lastMessageAt: Date?
        let unreadCount: Int
        let isSelfChat: Bool
        let displayMemberIDs: Data?
    }

    /// Get messages for a chat, optionally filtered by time.
    public func messages(chatId: Int64? = nil, since: Date? = nil, limit: Int = 50) throws -> [Message] {
        var conditions: [String] = []
        var bindings: [SQLValue] = []

        if let chatId {
            conditions.append("m.chatId = ?")
            bindings.append(.int64(chatId))
        }
        if let since {
            // KakaoTalk stores timestamps as seconds since epoch
            conditions.append("m.sentAt >= ?")
            bindings.append(.int64(Int64(since.timeIntervalSince1970)))
        }

        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
            SELECT m.logId, m.chatId, m.authorId,
                   COALESCE(u.displayName, u.friendNickName, u.nickName) as senderName,
                   m.message, m.type, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTUser u ON m.authorId = u.userId AND u.linkId = 0
            \(where_)
            ORDER BY m.sentAt DESC
            LIMIT ?
            """
        bindings.append(.int(limit))

        let myUserId = try self.myUserId()
        return try query(sql, bind: bindings) { row in
            Message(
                id: row.int64(0),
                chatId: row.int64(1),
                senderId: row.int64(2),
                senderName: row.string(3),
                text: row.string(4),
                type: Message.MessageType(rawValue: row.int(5)),
                createdAt: row.kakaoDate(6),
                isFromMe: row.int64(2) == myUserId
            )
        }
    }

    /// Full-text search across messages.
    public func search(query: String, limit: Int = 20) throws -> [Message] {
        let sql = """
            SELECT m.logId, m.chatId, m.authorId,
                   COALESCE(u.displayName, u.friendNickName, u.nickName) as senderName,
                   m.message, m.type, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTUser u ON m.authorId = u.userId AND u.linkId = 0
            WHERE m.message LIKE ?
            ORDER BY m.sentAt DESC
            LIMIT ?
            """
        let myUserId = try self.myUserId()
        return try self.query(sql, bind: [.string("%\(query)%"), .int(limit)]) { row in
            Message(
                id: row.int64(0),
                chatId: row.int64(1),
                senderId: row.int64(2),
                senderName: row.string(3),
                text: row.string(4),
                type: Message.MessageType(rawValue: row.int(5)),
                createdAt: row.kakaoDate(6),
                isFromMe: row.int64(2) == myUserId
            )
        }
    }

    /// Get the logged-in user's ID from NTChatContext.
    public func myUserId() throws -> Int64 {
        let results = try query("SELECT userId FROM NTChatContext LIMIT 2", bind: []) { row in
            row.int64(0)
        }
        guard results.count == 1, let value = results.first, value > 0 else {
            throw KakaoError.databaseOpenFailed("The current KakaoTalk user identity is ambiguous")
        }
        return value
    }

    private func currentUserDisplayName() throws -> String? {
        let values: [String?] = try query(
            """
            SELECT COALESCE(NULLIF(u.displayName, ''), NULLIF(u.nickName, ''), NULLIF(u.friendNickName, ''))
            FROM NTChatContext c
            JOIN NTUser u ON u.userId = c.userId AND u.linkId = 0
            LIMIT 2
            """,
            bind: []
        ) { $0.string(0) }
        guard values.count <= 1 else {
            throw KakaoError.databaseOpenFailed("The current KakaoTalk user identity is ambiguous")
        }
        return values.first.flatMap { $0 }
    }

    /// Get the maximum logId in the messages table (used by DatabaseWatcher).
    public func maxLogId() throws -> Int64 {
        let results = try query("SELECT MAX(logId) FROM NTChatMessage", bind: []) { row in
            row.optionalInt64(0)
        }
        return results.first.flatMap { $0 } ?? 0
    }

    public func maxLogId(chatId: Int64) throws -> Int64 {
        let results = try query(
            "SELECT MAX(logId) FROM NTChatMessage WHERE chatId = ?",
            bind: [.int64(chatId)]
        ) { $0.optionalInt64(0) }
        return results.first.flatMap { $0 } ?? 0
    }

    public func confirmedOutgoing(chatId: Int64, body: Data, after logId: Int64) throws -> Int64? {
        let sql = """
            SELECT logId FROM NTChatMessage
            WHERE chatId = ? AND logId > ? AND authorId = ?
              AND CAST(message AS BLOB) = ?
            ORDER BY logId ASC LIMIT 1
            """
        return try query(
            sql,
            bind: [.int64(chatId), .int64(logId), .int64(try myUserId()), .blob(body)]
        ) { $0.int64(0) }.first
    }

    /// Get messages with logId strictly greater than the given value.
    /// Returns SyncMessage structs suitable for JSON streaming.
    public func messagesSince(logId: Int64, myUserId: Int64) throws -> [SyncMessage] {
        let sql = """
            SELECT m.logId, m.chatId,
                   COALESCE(r.chatName, u.displayName, u.friendNickName, u.nickName) as chatName,
                   m.authorId,
                   COALESCE(u2.displayName, u2.friendNickName, u2.nickName) as senderName,
                   m.message, m.type, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTChatRoom r ON m.chatId = r.chatId
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            LEFT JOIN NTUser u2 ON m.authorId = u2.userId AND u2.linkId = 0
            WHERE m.logId > ?
            ORDER BY m.logId ASC
            LIMIT 100
            """
        let formatter = ISO8601DateFormatter()
        return try query(sql, bind: [.int64(logId)]) { row in
            SyncMessage(
                type: "message",
                logId: row.int64(0),
                chatId: row.int64(1),
                chatName: row.string(2),
                senderId: row.int64(3),
                senderName: row.string(4),
                text: row.string(5),
                messageType: row.int(6),
                timestamp: formatter.string(from: row.kakaoDate(7)),
                isFromMe: row.int64(3) == myUserId
            )
        }
    }

    /// Run an arbitrary read-only SQL query and return results as arrays of Any.
    public func rawQuery(_ sql: String) throws -> [[Any]] {
        var stmt: OpaquePointer?
        var trailingSQL = ""
        let prepareResult = sql.withCString { input -> Int32 in
            var tail: UnsafePointer<CChar>?
            let result = sqlite3_prepare_v2(db, input, -1, &stmt, &tail)
            if let tail { trailingSQL = String(cString: tail) }
            return result
        }
        guard prepareResult == SQLITE_OK, let stmt else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw KakaoError.sqlError("prepare: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        guard trailingSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KakaoError.sqlError("Only one SQL statement is allowed")
        }
        guard sqlite3_stmt_readonly(stmt) != 0 else {
            throw KakaoError.sqlError("Only read-only SQL statements are allowed")
        }

        let colCount = sqlite3_column_count(stmt)
        var results: [[Any]] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            var row: [Any] = []
            for i in 0..<colCount {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row.append(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:
                    row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(stmt, i) {
                        row.append(String(cString: text))
                    } else {
                        row.append("")
                    }
                case SQLITE_NULL:
                    row.append("")
                default:
                    row.append("")
                }
            }
            results.append(row)
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw KakaoError.sqlError("step: \(message)")
        }
        return results
    }

    /// Discover the actual database schema.
    public func schema() throws -> [(name: String, sql: String)] {
        try query(
            "SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name",
            bind: []
        ) { row in
            (name: row.string(0) ?? "", sql: row.string(1) ?? "")
        }
    }

    // MARK: - SQLite Helpers

    enum SQLValue {
        case int(Int)
        case int64(Int64)
        case double(Double)
        case string(String)
        case blob(Data)
        case null
    }

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw KakaoError.sqlError(msg)
        }
    }

    private func query<T>(_ sql: String, bind: [SQLValue], transform: (Row) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw KakaoError.sqlError("prepare: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int(stmt, idx, Int32(v))
            case .int64(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .string(let v): sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .blob(let data):
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        stmt, idx, bytes.baseAddress, Int32(data.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var results: [T] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            results.append(transform(Row(stmt: stmt!)))
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw KakaoError.sqlError("step: \(message)")
        }
        return results
    }

    struct Row {
        let stmt: OpaquePointer

        func int(_ col: Int32) -> Int {
            Int(sqlite3_column_int(stmt, col))
        }

        func int64(_ col: Int32) -> Int64 {
            sqlite3_column_int64(stmt, col)
        }

        func optionalInt64(_ col: Int32) -> Int64? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : int64(col)
        }

        func string(_ col: Int32) -> String? {
            guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: ptr)
        }

        func data(_ col: Int32) -> Data? {
            guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, col))
            guard count > 0, let bytes = sqlite3_column_blob(stmt, col) else { return nil }
            return Data(bytes: bytes, count: count)
        }

        func bool(_ col: Int32) -> Bool {
            sqlite3_column_int(stmt, col) != 0
        }

        /// KakaoTalk stores timestamps as seconds since epoch.
        func kakaoDate(_ col: Int32) -> Date {
            let ts = sqlite3_column_int64(stmt, col)
            return Date(timeIntervalSince1970: Double(ts))
        }

        func optionalKakaoDate(_ col: Int32) -> Date? {
            let val = sqlite3_column_int64(stmt, col)
            return val == 0 ? nil : Date(timeIntervalSince1970: Double(val))
        }
    }
}

extension Chat.ChatType {
    /// Map KakaoTalk's integer chat type to our enum.
    static func from(rawInt: Int) -> Self {
        // KakaoTalk uses integer types; exact mapping TBD via testing
        switch rawInt {
        case 0: return .direct
        case 1: return .group
        case 5: return .selfChat
        default: return .unknown
        }
    }
}
