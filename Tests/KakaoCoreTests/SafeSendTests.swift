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

    @Test("an unknown outcome is durable and never retried")
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
        #expect(database.confirmationCalls == 1)
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
        #expect(database.confirmationCalls == 0)
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
        #expect(try state.sendAttempt(requestID: request.requestID)?.receipt == receipt)
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
}

private final class MockDatabase: KakaoDatabaseAccess, @unchecked Sendable {
    let target: Chat
    var confirmedLogID: Int64?
    var confirmationChat: ChatID?
    var confirmationBody: Data?
    var confirmationAfter: Int64?
    var confirmationCalls = 0

    init(chat: Chat) { target = chat }
    func chats(limit: Int) throws -> [Chat] { [target] }
    func chat(id: ChatID) throws -> Chat? { id == target.id ? target : nil }
    func selfChat() throws -> Chat? { target.isSelfChat ? target : nil }
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
    private var attempts: [UUID: StoredSendAttempt] = [:]
    func sendAttempt(requestID: UUID) throws -> StoredSendAttempt? { attempts[requestID] }
    func saveSendAttempt(destinationKey: String, bodySHA256: String, receipt: SendReceipt) throws {
        attempts[receipt.requestID] = StoredSendAttempt(
            destinationKey: destinationKey,
            bodySHA256: bodySHA256,
            receipt: receipt
        )
    }
    func removeSendAttempt(requestID: UUID) throws { attempts.removeValue(forKey: requestID) }
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
