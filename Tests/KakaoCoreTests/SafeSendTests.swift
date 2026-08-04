import CryptoKit
import Foundation
import Testing
@testable import KakaoCore

@Suite("Safe sender")
struct SafeSendTests {
    private let target = Chat(
        id: ChatID(rawValue: 123),
        type: .direct,
        displayName: "Exact Room",
        memberCount: 2,
        lastMessageId: 8,
        lastMessageAt: nil,
        unreadCount: 0
    )

    @Test("recognizes only selected structural Chats navigation controls")
    func chatsNavigation() {
        #expect(SendUIValidator.isSelectedChatsNavigation(
            NavigationControlEvidence(
                role: "AXCheckBox", identifier: "chatrooms",
                title: nil, description: nil, selected: true
            )
        ))
        #expect(!SendUIValidator.isSelectedChatsNavigation(
            NavigationControlEvidence(
                role: "AXCheckBox", identifier: "chatrooms",
                title: nil, description: nil, selected: false
            )
        ))
        #expect(!SendUIValidator.isSelectedChatsNavigation(
            NavigationControlEvidence(
                role: "AXCheckBox", identifier: "friends",
                title: "Chats", description: nil, selected: true
            )
        ))
        #expect(SendUIValidator.isSelectedChatsNavigation(
            NavigationControlEvidence(
                role: "AXButton", identifier: nil,
                title: "Chats", description: nil, selected: true
            )
        ))
    }

    @Test("rejects stale or unrelated windows")
    func staleWindows() throws {
        #expect(throws: SendUIError.self) {
            try SendUIValidator.preparation(
                expectedTitle: "Exact Room",
                openRooms: [OpenRoomEvidence(title: "Other Room", composerCount: 1, composerText: "")],
                matchingRowCount: 1
            )
        }
        #expect(throws: SendUIError.self) {
            try SendUIValidator.preparation(
                expectedTitle: "Exact Room",
                openRooms: [OpenRoomEvidence(title: "Exact Room", composerCount: 1, composerText: "")],
                matchingRowCount: 1
            )
        }
        #expect(throws: SendUIError.self) {
            try SendUIValidator.preparation(
                expectedTitle: "Exact Room",
                openRooms: [
                    OpenRoomEvidence(title: "Exact Room", composerCount: 1, composerText: ""),
                    OpenRoomEvidence(title: "Other Room", composerCount: 1, composerText: ""),
                ],
                matchingRowCount: 1
            )
        }
    }

    @Test("rejects duplicate UI labels")
    func duplicateRows() throws {
        #expect(throws: SendUIError.self) {
            try SendUIValidator.preparation(
                expectedTitle: "Exact Room",
                openRooms: [],
                matchingRowCount: 2
            )
        }
    }

    @Test("rejects a nonempty draft and ambiguous composer")
    func draft() throws {
        #expect(throws: SendUIError.self) {
            try SendUIValidator.preparation(
                expectedTitle: "Exact Room",
                openRooms: [OpenRoomEvidence(title: "Exact Room", composerCount: 1, composerText: "draft")],
                matchingRowCount: 1
            )
        }
        #expect(throws: SendUIError.self) {
            try SendUIValidator.preparation(
                expectedTitle: "Exact Room",
                openRooms: [OpenRoomEvidence(title: "Exact Room", composerCount: 2, composerText: "")],
                matchingRowCount: 1
            )
        }
    }

    @Test("final action validation rejects focus, title, window, and composer changes")
    func finalActionChanges() throws {
        let valid = FinalRoomEvidence(
            applicationRunning: true,
            exactWindowSet: true,
            mainWindowIdentifier: "Main Window",
            roomTitle: "Exact Room",
            composerCount: 1,
            composerIdentityMatches: true,
            composerFocused: true,
            composerBody: "exact body"
        )
        try SendUIValidator.verifyFinalRoom(
            expectedTitle: "Exact Room",
            expectedBody: "exact body",
            evidence: valid
        )

        let changed = [
            FinalRoomEvidence(
                applicationRunning: true, exactWindowSet: false,
                mainWindowIdentifier: "Main Window", roomTitle: "Exact Room",
                composerCount: 1, composerIdentityMatches: true,
                composerFocused: true, composerBody: "exact body"
            ),
            FinalRoomEvidence(
                applicationRunning: true, exactWindowSet: true,
                mainWindowIdentifier: "Main Window", roomTitle: "Wrong Room",
                composerCount: 1, composerIdentityMatches: true,
                composerFocused: true, composerBody: "exact body"
            ),
            FinalRoomEvidence(
                applicationRunning: true, exactWindowSet: true,
                mainWindowIdentifier: "Main Window", roomTitle: "Exact Room",
                composerCount: 1, composerIdentityMatches: true,
                composerFocused: false, composerBody: "exact body"
            ),
            FinalRoomEvidence(
                applicationRunning: true, exactWindowSet: true,
                mainWindowIdentifier: "Main Window", roomTitle: "Exact Room",
                composerCount: 1, composerIdentityMatches: false,
                composerFocused: true, composerBody: "changed"
            ),
        ]
        for evidence in changed {
            #expect(throws: SendUIError.self) {
                try SendUIValidator.verifyFinalRoom(
                    expectedTitle: "Exact Room",
                    expectedBody: "exact body",
                    evidence: evidence
                )
            }
        }
    }

    @Test("confirms exact bytes only in intended chat")
    func exactDatabaseConfirmation() throws {
        let database = MockDatabase(chat: target)
        database.confirmedLogID = 99
        let state = MockState()
        let ui = MockUI()
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let request = SendRequest(
            requestID: UUID(),
            destination: .chatID(target.id),
            body: "byte-exact 🫧"
        )
        let receipt = try coordinator.send(request)
        #expect(receipt.status == .confirmed)
        #expect(receipt.logID == 99)
        #expect(database.confirmationChat == target.id)
        #expect(database.confirmationBody == Data("byte-exact 🫧".utf8))
        #expect(database.confirmationAfter == 8)
        #expect(ui.calls == 1)
    }

    @Test("an unknown outcome is durable and never retries the UI")
    func unknownIdempotency() throws {
        let database = MockDatabase(chat: target)
        let state = MockState()
        let ui = MockUI()
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let request = SendRequest(requestID: UUID(), destination: .chatID(target.id), body: "once")
        let first = try coordinator.send(request)
        let second = try coordinator.send(request)
        #expect(first.status == .unknown)
        #expect(second == first)
        #expect(ui.calls == 1)
        #expect(database.confirmationCalls == 2)
    }

    @Test("a stored unknown can be confirmed later without another UI action")
    func lateConfirmation() throws {
        let database = MockDatabase(chat: target)
        let state = MockState()
        let ui = MockUI()
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let request = SendRequest(requestID: UUID(), destination: .chatID(target.id), body: "arrives later")
        #expect(try coordinator.send(request).status == .unknown)
        database.confirmedLogID = 104
        let reconciled = try coordinator.send(request)
        #expect(reconciled.status == .confirmed)
        #expect(reconciled.logID == 104)
        #expect(ui.calls == 1)
    }

    @Test("a stored unknown cannot claim a log owned by another request ID")
    func lateConfirmationDoesNotStealLog() throws {
        let database = MockDatabase(chat: target)
        let state = MockState()
        let ui = MockUI()
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let first = SendRequest(requestID: UUID(), destination: .chatID(target.id), body: "same body")
        #expect(try coordinator.send(first).status == .unknown)

        let secondID = UUID()
        let body = Data(first.body.utf8)
        try state.saveSendAttempt(
            destinationKey: first.destination.storageKey,
            bodySHA256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
            body: body,
            highWatermark: 8,
            receipt: SendReceipt(
                requestID: secondID,
                chatID: target.id,
                logID: nil,
                status: .unknown
            )
        )
        #expect(try state.claimConfirmedSendAttempt(
            destinationKey: first.destination.storageKey,
            bodySHA256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
            body: body,
            highWatermark: 8,
            receipt: SendReceipt(
                requestID: secondID,
                chatID: target.id,
                logID: 104,
                status: .confirmed
            )
        ))

        database.confirmedLogID = 104
        let replay = try coordinator.send(first)
        #expect(replay.status == .unknown)
        #expect(replay.logID == nil)
        #expect(ui.calls == 1)
    }

    @Test("uncertainty from the UI is stored as unknown")
    func uiUncertainty() throws {
        let database = MockDatabase(chat: target)
        let state = MockState()
        let ui = MockUI()
        ui.error = .outcomeUnknown("cannot prove")
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let receipt = try coordinator.send(
            SendRequest(requestID: UUID(), destination: .chatID(target.id), body: "maybe")
        )
        #expect(receipt.status == .unknown)
        #expect(database.confirmationCalls == 1)
    }

    @Test("uncertainty from the UI still receives read-only database confirmation")
    func uiUncertaintyConfirmed() throws {
        let database = MockDatabase(chat: target)
        database.confirmedLogID = 103
        let state = MockState()
        let ui = MockUI()
        ui.error = .outcomeUnknown("AX acknowledgement unavailable")
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let receipt = try coordinator.send(
            SendRequest(requestID: UUID(), destination: .chatID(target.id), body: "confirm-only")
        )
        #expect(receipt.status == .confirmed)
        #expect(receipt.logID == 103)
        #expect(ui.calls == 1)
    }

    @Test("rejects a display identity shared by multiple database chats")
    func duplicateDatabaseIdentity() throws {
        let database = MockDatabase(chat: target)
        database.uiIdentityCount = 2
        let ui = MockUI()
        let coordinator = SafeSendCoordinator(
            database: database,
            state: MockState(),
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        #expect(throws: KakaoClientError.self) {
            try coordinator.send(
                SendRequest(requestID: UUID(), destination: .chatID(target.id), body: "ambiguous")
            )
        }
        #expect(ui.calls == 0)
    }

    @Test("request is reserved before UI action and confirmed receipts replace the reservation")
    func preActionReservation() throws {
        let database = MockDatabase(chat: target)
        database.confirmedLogID = 101
        let state = MockState()
        let ui = MockUI()
        let request = SendRequest(requestID: UUID(), destination: .chatID(target.id), body: "reserved")
        ui.onSubmit = {
            let attempt = try state.sendAttempt(requestID: request.requestID)
            #expect(attempt?.receipt.status == .unknown)
        }
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let receipt = try coordinator.send(request)
        #expect(receipt.status == .confirmed)
        let stored = try state.sendAttempt(requestID: request.requestID)
        #expect(stored?.receipt == receipt)
        #expect(stored?.body == Data(request.body.utf8))
        #expect(stored?.highWatermark == 8)
    }

    @Test("precondition failure clears the reservation for a same-ID retry")
    func preconditionRetry() throws {
        let database = MockDatabase(chat: target)
        database.confirmedLogID = 102
        let state = MockState()
        let ui = MockUI()
        ui.error = .preconditionFailed("not ready")
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let request = SendRequest(requestID: UUID(), destination: .chatID(target.id), body: "retry")
        #expect(throws: KakaoClientError.self) { try coordinator.send(request) }
        #expect(try state.sendAttempt(requestID: request.requestID) == nil)
        ui.error = nil
        #expect(try coordinator.send(request).status == .confirmed)
        #expect(ui.calls == 2)
    }

    @Test("request IDs cannot be reused with different content")
    func requestConflict() throws {
        let database = MockDatabase(chat: target)
        let state = MockState()
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: MockUI(),
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let id = UUID()
        _ = try coordinator.send(SendRequest(requestID: id, destination: .chatID(target.id), body: "first"))
        #expect(throws: KakaoClientError.self) {
            try coordinator.send(SendRequest(requestID: id, destination: .chatID(target.id), body: "second"))
        }
    }

    @Test("rejects an oversized body before UI work")
    func oversizedBody() throws {
        let ui = MockUI()
        let coordinator = SafeSendCoordinator(
            database: MockDatabase(chat: target),
            state: MockState(),
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let body = String(repeating: "a", count: KakaoLimits.maximumSendBodyBytes + 1)
        #expect(throws: KakaoClientError.self) {
            try coordinator.send(
                SendRequest(requestID: UUID(), destination: .chatID(target.id), body: body)
            )
        }
        #expect(ui.calls == 0)
    }

    @Test("chat-ID resolution bypasses previously listed display data")
    func freshChatIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("KakaoTalk.sqlite").path
        try runSQLite(path: path, sql: """
            CREATE TABLE NTChatContext(userId INTEGER);
            CREATE TABLE NTUser(
                userId INTEGER, linkId INTEGER, displayName TEXT,
                friendNickName TEXT, nickName TEXT
            );
            CREATE TABLE NTChatRoom(
                chatId INTEGER, type INTEGER, chatName TEXT,
                activeMembersCount INTEGER, lastLogId INTEGER,
                lastUpdatedAt INTEGER, countOfNewMessage INTEGER,
                directChatMemberUserId INTEGER, displayMemberIds BLOB
            );
            CREATE TABLE NTChatMeta(
                chatId INTEGER, type INTEGER, groupNickname TEXT, content TEXT
            );
            INSERT INTO NTChatContext VALUES(999);
            INSERT INTO NTUser VALUES(999, 0, 'Owner', NULL, NULL);
            INSERT INTO NTChatRoom VALUES(123, 0, 'Old Name', 2, 8, 1, 0, NULL, NULL);
            """)
        let reader = DatabaseReader(databasePath: path)
        try reader.open()
        defer { reader.close() }
        #expect(try reader.chats(limit: 50).first?.displayName == "Old Name")
        try runSQLite(path: path, sql: "UPDATE NTChatRoom SET chatName = 'Fresh Name' WHERE chatId = 123;")
        #expect(try reader.chat(id: target.id)?.displayName == "Fresh Name")
    }

    @Test("confirmed receipt recovery proves the exact outgoing row and is idempotent")
    func confirmedReceiptRecovery() throws {
        let database = MockDatabase(chat: target)
        database.confirmedLogID = 77
        let state = MockState()
        let importer = ConfirmedReceiptImporter(database: database, state: state)
        let request = SendRequest(
            requestID: UUID(),
            destination: .chatID(target.id),
            body: "already sent"
        )

        let first = try importer.importReceipt(request: request, chatID: target.id, logID: 77)
        let second = try importer.importReceipt(request: request, chatID: target.id, logID: 77)

        #expect(first == second)
        #expect(first.status == .confirmed)
        #expect(first.logID == 77)
        #expect(database.confirmationChat == target.id)
        #expect(database.confirmationBody == Data("already sent".utf8))
        #expect(database.confirmationAfter == 76)
    }

    @Test("confirmed receipt recovery rejects unproved rows and duplicate log ownership")
    func confirmedReceiptRecoveryRejectsConflicts() throws {
        let database = MockDatabase(chat: target)
        let state = MockState()
        let importer = ConfirmedReceiptImporter(database: database, state: state)
        let unproved = SendRequest(
            requestID: UUID(), destination: .chatID(target.id), body: "missing"
        )
        #expect(throws: KakaoClientError.self) {
            try importer.importReceipt(request: unproved, chatID: target.id, logID: 88)
        }
        #expect(try state.sendAttempt(requestID: unproved.requestID) == nil)

        database.confirmedLogID = 88
        let first = SendRequest(
            requestID: UUID(), destination: .chatID(target.id), body: "present"
        )
        let second = SendRequest(
            requestID: UUID(), destination: .chatID(target.id), body: "present"
        )
        _ = try importer.importReceipt(request: first, chatID: target.id, logID: 88)
        #expect(throws: KakaoClientError.self) {
            try importer.importReceipt(request: second, chatID: target.id, logID: 88)
        }
        #expect(try state.sendAttempt(requestID: second.requestID) == nil)
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
            throw KakaoClientError.state(
                String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }
    }
}

private final class MockDatabase: KakaoDatabaseAccess, @unchecked Sendable {
    let target: Chat
    var confirmedLogID: Int64?
    var confirmationChat: ChatID?
    var confirmationBody: Data?
    var confirmationAfter: Int64?
    var confirmationCalls = 0
    var uiIdentityCount = 1

    init(chat: Chat) { target = chat }
    func chats(limit: Int) throws -> [Chat] { [target] }
    func chat(id: ChatID) throws -> Chat? { id == target.id ? target : nil }
    func selfChat() throws -> Chat? { target.isSelfChat ? target : nil }
    func chatUIIdentityCount(displayName: String) throws -> Int { uiIdentityCount }
    func messages(chatID: ChatID?, since: Date?, limit: Int) throws -> [Message] { [] }
    func maxLogID(chatID: ChatID?) throws -> Int64 { 8 }
    func messagesSince(logID: Int64, limit: Int) throws -> [Message] { [] }
    func confirmedOutgoing(chatID: ChatID, body: Data, after logID: Int64) throws -> Int64? {
        confirmationCalls += 1
        confirmationChat = chatID
        confirmationBody = body
        confirmationAfter = logID
        return confirmedLogID
    }
    func attachmentMetadata(logID: Int64) throws -> String? { nil }
}

private final class MockState: SendStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [UUID: StoredSendAttempt] = [:]
    private var logOwners: [Int64: UUID] = [:]
    func sendAttempt(requestID: UUID) throws -> StoredSendAttempt? {
        lock.lock()
        defer { lock.unlock() }
        return attempts[requestID]
    }
    func saveSendAttempt(
        destinationKey: String,
        bodySHA256: String,
        body: Data,
        highWatermark: Int64,
        receipt: SendReceipt
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        attempts[receipt.requestID] = StoredSendAttempt(
            destinationKey: destinationKey,
            bodySHA256: bodySHA256,
            body: body,
            highWatermark: highWatermark,
            receipt: receipt
        )
    }
    func claimConfirmedSendAttempt(
        destinationKey: String,
        bodySHA256: String,
        body: Data,
        highWatermark: Int64,
        receipt: SendReceipt
    ) throws -> Bool {
        guard let logID = receipt.logID else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let owner = logOwners[logID], owner != receipt.requestID { return false }
        guard let stored = attempts[receipt.requestID],
              stored.destinationKey == destinationKey,
              stored.bodySHA256 == bodySHA256 else { return false }
        logOwners[logID] = receipt.requestID
        attempts[receipt.requestID] = StoredSendAttempt(
            destinationKey: destinationKey,
            bodySHA256: bodySHA256,
            body: body,
            highWatermark: highWatermark,
            receipt: receipt
        )
        return true
    }
    func removeSendAttempt(requestID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        attempts.removeValue(forKey: requestID)
    }
}

private final class MockUI: KakaoSendUI, @unchecked Sendable {
    var calls = 0
    var error: SendUIError?
    var onSubmit: (() throws -> Void)?
    func submit(chat: Chat, body: String) throws {
        calls += 1
        try onSubmit?()
        if let error { throw error }
    }
}

private final class MockLock: SendTransactionLocking, @unchecked Sendable {
    func lock() throws {}
    func unlock() {}
}
