import Foundation
import Testing
@testable import KakaoCore

@Suite("Database-backed send identity")
struct DatabaseSendIdentityTests {
    @Test("chat ID is resolved freshly and duplicate UI identities are counted database-wide")
    func freshExactResolution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("KakaoTalk.sqlite").path
        try runSQLite(
            path: path,
            sql: schema + """
            INSERT INTO NTChatContext VALUES(1);
            INSERT INTO NTUser VALUES(1, 0, 'Owner', NULL, 'Owner');
            INSERT INTO NTUser VALUES(2, 0, 'Remote', 'Before', 'Remote');
            INSERT INTO NTChatRoom VALUES(10, 1, NULL, 2, 8, 100, 0, 2, NULL);
            """
        )

        let reader = DatabaseReader(databasePath: path)
        try reader.open()
        defer { reader.close() }
        #expect(try reader.chat(id: 10)?.displayName == "Before")

        try runSQLite(
            path: path,
            sql: """
            UPDATE NTUser SET friendNickName='After' WHERE userId=2;
            INSERT INTO NTUser VALUES(3, 0, 'Someone', 'After', 'Someone');
            INSERT INTO NTChatRoom VALUES(11, 1, NULL, 2, 9, 101, 0, 3, NULL);
            """
        )
        #expect(try reader.chat(id: 10)?.displayName == "After")
        #expect(try reader.chatUIIdentityCount(displayName: "After") == 2)
        #expect(try reader.chat(id: 999) == nil)
    }

    @Test("blank-name groups require matching current membership and harvested UI identity")
    func participantVerifiedGroupIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("KakaoTalk.sqlite").path
        let memberIDs: [Int64] = [20, 30, 40, 50]
        let memberData = try PropertyListSerialization.data(
            fromPropertyList: memberIDs,
            format: .binary,
            options: 0
        )
        let memberHex = memberData.map { String(format: "%02x", $0) }.joined()
        try runSQLite(
            path: path,
            sql: schema + """
            INSERT INTO NTChatContext VALUES(10);
            INSERT INTO NTUser VALUES(10, 0, 'Owner', NULL, 'Owner');
            INSERT INTO NTUser VALUES(20, 0, 'Chase', 'Chase', 'Chase');
            INSERT INTO NTUser VALUES(30, 0, 'Anna', 'Anna', 'Anna');
            INSERT INTO NTUser VALUES(40, 0, 'Stella', 'Stella', 'Stella');
            INSERT INTO NTUser VALUES(50, 0, 'YJ', 'YJ', 'YJ');
            INSERT INTO NTChatRoom VALUES(
                77, 1, NULL, 5, 9, 101, 0, 0, X'\(memberHex)'
            );
            """
        )
        let metadata = try MetadataStore(
            directory: root.appendingPathComponent("state", isDirectory: true)
        )
        metadata.update(
            chatId: 77,
            name: "Anna, Chase, Stella, YJ",
            memberCount: 5,
            chatType: 1,
            messageCount: 20
        )
        try metadata.save()

        let reader = DatabaseReader(databasePath: path, metadataStore: metadata)
        try reader.open()
        defer { reader.close() }
        #expect(try reader.chat(id: 77)?.displayName == "Anna, Chase, Stella, YJ")
        #expect(try reader.chatUIIdentityCount(displayName: "Anna, Chase, Stella, YJ") == 1)

        try runSQLite(
            path: path,
            sql: "UPDATE NTUser SET friendNickName='Changed YJ' WHERE userId=50;"
        )
        #expect(try reader.chat(id: 77)?.displayName == "(unknown)")

        try runSQLite(
            path: path,
            sql: "UPDATE NTUser SET friendNickName='YJ' WHERE userId=50;"
        )
        metadata.update(
            chatId: 77,
            name: "Anna, Chase, Stella, YJ",
            memberCount: 4,
            chatType: 1
        )
        #expect(try reader.chat(id: 77)?.displayName == "(unknown)")
    }

    @Test("current-user identity must be exactly one positive row")
    func currentUserIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("KakaoTalk.sqlite").path
        try runSQLite(
            path: path,
            sql: schema + """
            INSERT INTO NTChatContext VALUES(1);
            INSERT INTO NTChatContext VALUES(2);
            INSERT INTO NTUser VALUES(1, 0, 'Owner', NULL, 'Owner');
            INSERT INTO NTUser VALUES(2, 0, 'Other', NULL, 'Other');
            """
        )
        let reader = DatabaseReader(databasePath: path)
        try reader.open()
        defer { reader.close() }
        #expect(throws: KakaoError.self) { try reader.myUserId() }
    }

    private var schema: String {
        """
        CREATE TABLE NTChatContext(userId INTEGER);
        CREATE TABLE NTUser(
            userId INTEGER,
            linkId INTEGER,
            displayName TEXT,
            friendNickName TEXT,
            nickName TEXT
        );
        CREATE TABLE NTChatRoom(
            chatId INTEGER PRIMARY KEY,
            type INTEGER,
            chatName TEXT,
            activeMembersCount INTEGER,
            lastLogId INTEGER,
            lastUpdatedAt INTEGER,
            countOfNewMessage INTEGER,
            directChatMemberUserId INTEGER,
            displayMemberIds BLOB
        );
        CREATE TABLE NTChatMessage(
            logId INTEGER PRIMARY KEY,
            chatId INTEGER,
            authorId INTEGER,
            message TEXT,
            type INTEGER,
            sentAt INTEGER
        );
        """
    }

    private func runSQLite(path: String, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SafeSendError.state(
                String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }
    }
}
