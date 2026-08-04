import ApplicationServices
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

    @Test("recognizes the current stateless navigation only with one certified chat table")
    func currentStatelessChatsNavigation() {
        let navigation = ["friends", "chatrooms", "more"].map { identifier in
            NavigationControlEvidence(
                role: "AXButton", identifier: identifier,
                title: nil, description: nil, selected: nil,
                enabled: true
            )
        }
        #expect(SendUIValidator.isStatelessChatsNavigationSet(navigation))
        #expect(SendUIValidator.isVerifiedChatList(
            navigationControls: navigation,
            tableCandidateCount: 1
        ))
        #expect(!SendUIValidator.isVerifiedChatList(
            navigationControls: navigation,
            tableCandidateCount: 0
        ))
        #expect(!SendUIValidator.isVerifiedChatList(
            navigationControls: navigation,
            tableCandidateCount: 2
        ))

        var deselected = navigation
        deselected[1] = NavigationControlEvidence(
            role: "AXButton", identifier: "chatrooms",
            title: nil, description: nil, selected: false,
            enabled: true
        )
        #expect(!SendUIValidator.isVerifiedChatList(
            navigationControls: deselected,
            tableCandidateCount: 1
        ))

        var duplicate = navigation
        duplicate.append(navigation[1])
        #expect(!SendUIValidator.isStatelessChatsNavigationSet(duplicate))

        var disabled = navigation
        disabled[1] = NavigationControlEvidence(
            role: "AXButton", identifier: "chatrooms",
            title: nil, description: nil, selected: nil,
            enabled: false
        )
        #expect(!SendUIValidator.isStatelessChatsNavigationSet(disabled))
    }

    @Test("requires the complete current Kakao chat-row schema")
    func currentChatRowStructure() {
        let current = ChatRowStructureEvidence(
            nonemptyNameLabelCount: 1,
            profileControlCount: 1,
            metadataLabelCount: 1,
            messagePreviewCount: 1
        )
        #expect(SendUIValidator.isChatRowStructure(current))

        let invalid = [
            ChatRowStructureEvidence(
                nonemptyNameLabelCount: 0, profileControlCount: 1,
                metadataLabelCount: 1, messagePreviewCount: 1
            ),
            ChatRowStructureEvidence(
                nonemptyNameLabelCount: 2, profileControlCount: 1,
                metadataLabelCount: 1, messagePreviewCount: 1
            ),
            ChatRowStructureEvidence(
                nonemptyNameLabelCount: 1, profileControlCount: 0,
                metadataLabelCount: 1, messagePreviewCount: 1
            ),
            ChatRowStructureEvidence(
                nonemptyNameLabelCount: 1, profileControlCount: 1,
                metadataLabelCount: 0, messagePreviewCount: 1
            ),
            ChatRowStructureEvidence(
                nonemptyNameLabelCount: 1, profileControlCount: 1,
                metadataLabelCount: 1, messagePreviewCount: 0
            ),
        ]
        for evidence in invalid {
            #expect(!SendUIValidator.isChatRowStructure(evidence))
        }
    }

    @Test("clean composition fingerprint rejects queued and nested state")
    func cleanCompositionFingerprint() {
        #expect(CompositionWindowValidator.isClean(cleanCompositionEvidence()))
        #expect(!CompositionWindowValidator.isClean(cleanCompositionEvidence(
            directChildCount: 21
        )))

        var duplicateIdentifiers = certifiedCompositionElements
        duplicateIdentifiers[0] = duplicateIdentifiers[1]
        #expect(!CompositionWindowValidator.isClean(cleanCompositionEvidence(
            identifiedDirectChildren: duplicateIdentifiers
        )))
        #expect(!CompositionWindowValidator.isClean(cleanCompositionEvidence(
            fixedLeavesAreEmpty: false
        )))
        #expect(!CompositionWindowValidator.isClean(cleanCompositionEvidence(
            sliderIsClean: false
        )))
        #expect(!CompositionWindowValidator.isClean(cleanCompositionEvidence(
            emptyButtonCount: 7,
            nestedButtonCount: 2
        )))
        #expect(!CompositionWindowValidator.isClean(cleanCompositionEvidence(
            nestedButtonIsClean: false
        )))
        #expect(!CompositionWindowValidator.isClean(cleanCompositionEvidence(
            composerIsOnlyChild: false
        )))
        #expect(!CompositionWindowValidator.isClean(cleanCompositionEvidence(
            composerIsLeaf: false
        )))
    }

    @Test("allows unrelated verified rooms but keeps exact-target checks")
    func multipleRooms() throws {
        #expect(try SendUIValidator.preparation(
            expectedTitle: "Exact Room",
            openRooms: [OpenRoomEvidence(title: "Other Room", composerCount: 1, composerText: "draft")],
            matchingRowCount: 1
        ) == .openExactRow)
        #expect(try SendUIValidator.preparation(
            expectedTitle: "Exact Room",
            openRooms: [OpenRoomEvidence(title: "Exact Room", composerCount: 1, composerText: "")],
            matchingRowCount: 1
        ) == .reuse)
        #expect(try SendUIValidator.preparation(
            expectedTitle: "Exact Room",
            openRooms: [
                OpenRoomEvidence(title: "Exact Room", composerCount: 1, composerText: ""),
                OpenRoomEvidence(title: "Other Room", composerCount: 1, composerText: "draft"),
            ],
            matchingRowCount: 1
        ) == .reuse)
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

    @Test("reuse still requires one exact destination row")
    func reuseRequiresExactRow() {
        let room = OpenRoomEvidence(title: "Exact Room", composerCount: 1, composerText: "")
        #expect(throws: SendUIError.self) {
            try SendUIValidator.preparation(
                expectedTitle: "Exact Room", openRooms: [room], matchingRowCount: 0
            )
        }
        #expect(throws: SendUIError.self) {
            try SendUIValidator.preparation(
                expectedTitle: "Exact Room", openRooms: [room], matchingRowCount: 2
            )
        }
    }

    @Test("final action validation rejects title, window, and composer changes")
    func finalActionChanges() throws {
        let valid = FinalRoomEvidence(
            applicationRunning: true,
            exactWindowSet: true,
            mainWindowIdentifier: "Main Window",
            roomTitle: "Exact Room",
            composerCount: 1,
            composerIdentityMatches: true,
            composerBody: "exact body",
            frontmostApplicationUnchanged: true
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
                composerBody: "exact body", frontmostApplicationUnchanged: true
            ),
            FinalRoomEvidence(
                applicationRunning: true, exactWindowSet: true,
                mainWindowIdentifier: "Main Window", roomTitle: "Wrong Room",
                composerCount: 1, composerIdentityMatches: true,
                composerBody: "exact body", frontmostApplicationUnchanged: true
            ),
            FinalRoomEvidence(
                applicationRunning: true, exactWindowSet: true,
                mainWindowIdentifier: "Main Window", roomTitle: "Exact Room",
                composerCount: 2, composerIdentityMatches: true,
                composerBody: "exact body", frontmostApplicationUnchanged: true
            ),
            FinalRoomEvidence(
                applicationRunning: true, exactWindowSet: true,
                mainWindowIdentifier: "Main Window", roomTitle: "Exact Room",
                composerCount: 1, composerIdentityMatches: false,
                composerBody: "changed", frontmostApplicationUnchanged: true
            ),
            FinalRoomEvidence(
                applicationRunning: true, exactWindowSet: true,
                mainWindowIdentifier: "Main Window", roomTitle: "Exact Room",
                composerCount: 1, composerIdentityMatches: true,
                composerBody: "exact body", frontmostApplicationUnchanged: false
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

    @Test("automatic warm-up completes before reservation and submit")
    func automaticWarmupOrdering() throws {
        let database = MockDatabase(chat: target)
        database.confirmedLogID = 109
        let state = MockState()
        let ui = MockUI()
        let request = SendRequest(
            requestID: UUID(), destination: .chatID(target.id), body: "after warm-up"
        )
        ui.onPrepare = {
            let attempt = try state.sendAttempt(requestID: request.requestID)
            #expect(attempt == nil)
        }
        ui.onSubmit = {
            let attempt = try state.sendAttempt(requestID: request.requestID)
            #expect(attempt != nil)
        }
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )

        #expect(try coordinator.send(request).status == .confirmed)
        #expect(ui.prepareCalls == 1)
        #expect(ui.calls == 1)
    }

    @Test("standalone warm-up writes no send state and never submits")
    func standaloneWarmupIsNoSend() throws {
        let state = MockState()
        let ui = MockUI()
        ui.warmupStatus = .opened
        let coordinator = SafeSendCoordinator(
            database: MockDatabase(chat: target),
            state: state,
            ui: ui,
            roomPreparer: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )

        let receipt = try coordinator.warmup(.chatID(target.id))
        #expect(receipt == RoomWarmupReceipt(chatID: target.id, status: .opened))
        #expect(ui.prepareCalls == 1)
        #expect(ui.calls == 0)
        #expect(state.attemptCount == 0)
    }

    @Test("database identity drift after warm-up blocks reservation and submit")
    func warmupIdentityDrift() throws {
        let database = MockDatabase(chat: target)
        let state = MockState()
        let ui = MockUI()
        ui.onPrepare = {
            database.resolvedChat = Chat(
                id: self.target.id,
                type: self.target.type,
                displayName: "Renamed Room",
                memberCount: self.target.memberCount,
                lastMessageId: self.target.lastMessageId,
                lastMessageAt: self.target.lastMessageAt,
                unreadCount: self.target.unreadCount
            )
        }
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            roomPreparer: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let request = SendRequest(
            requestID: UUID(), destination: .chatID(target.id), body: "identity changed"
        )

        #expect(throws: KakaoClientError.self) { try coordinator.send(request) }
        #expect(ui.prepareCalls == 1)
        #expect(ui.calls == 0)
        #expect(state.attemptCount == 0)
    }

    @Test("database identity drift at the final UI boundary clears the reservation")
    func finalIdentityDrift() throws {
        let database = MockDatabase(chat: target)
        let state = MockState()
        let ui = MockUI()
        ui.onBeforeFinalIdentityCheck = {
            database.resolvedChat = Chat(
                id: self.target.id,
                type: self.target.type,
                displayName: "Last-Moment Rename",
                memberCount: self.target.memberCount,
                lastMessageId: self.target.lastMessageId,
                lastMessageAt: self.target.lastMessageAt,
                unreadCount: self.target.unreadCount
            )
        }
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            roomPreparer: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let request = SendRequest(
            requestID: UUID(), destination: .chatID(target.id), body: "final drift"
        )

        #expect(throws: KakaoClientError.self) { try coordinator.send(request) }
        #expect(ui.prepareCalls == 1)
        #expect(ui.calls == 1)
        #expect(state.attemptCount == 0)
    }

    @Test("stored requests reconcile without warming a room")
    func storedRequestSkipsWarmup() throws {
        let database = MockDatabase(chat: target)
        let state = MockState()
        let ui = MockUI()
        let coordinator = SafeSendCoordinator(
            database: database,
            state: state,
            ui: ui,
            roomPreparer: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let request = SendRequest(
            requestID: UUID(), destination: .chatID(target.id), body: "stored"
        )
        #expect(try coordinator.send(request).status == .unknown)
        #expect(ui.prepareCalls == 1)
        #expect(ui.calls == 1)
        #expect(try coordinator.send(request).status == .unknown)
        #expect(ui.prepareCalls == 1)
        #expect(ui.calls == 1)
    }

    @Test("warm-up failure is retry-safe and creates no reservation")
    func warmupFailureCreatesNoReservation() throws {
        let state = MockState()
        let ui = MockUI()
        ui.prepareError = .preconditionFailed("activation changed")
        let coordinator = SafeSendCoordinator(
            database: MockDatabase(chat: target),
            state: state,
            ui: ui,
            roomPreparer: ui,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let request = SendRequest(
            requestID: UUID(), destination: .chatID(target.id), body: "never composed"
        )

        #expect(throws: KakaoClientError.self) { try coordinator.send(request) }
        #expect(ui.prepareCalls == 1)
        #expect(ui.calls == 0)
        #expect(state.attemptCount == 0)
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

    @Test("post-action transport and confirmation errors return durable unknown")
    func postActionErrorsRemainUnknown() throws {
        struct UnexpectedTransportError: Error {}

        let transportDatabase = MockDatabase(chat: target)
        let transportState = MockState()
        let transportUI = MockUI()
        transportUI.onSubmit = { throw UnexpectedTransportError() }
        let transportCoordinator = SafeSendCoordinator(
            database: transportDatabase,
            state: transportState,
            ui: transportUI,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let transportRequest = SendRequest(
            requestID: UUID(), destination: .chatID(target.id), body: "transport uncertain"
        )
        #expect(try transportCoordinator.send(transportRequest).status == .unknown)
        #expect(try transportCoordinator.send(transportRequest).status == .unknown)
        #expect(transportUI.calls == 1)
        #expect(try transportState.sendAttempt(requestID: transportRequest.requestID)?.receipt.status == .unknown)

        let confirmationDatabase = MockDatabase(chat: target)
        confirmationDatabase.confirmationError = KakaoClientError.state("confirmation read failed")
        let confirmationState = MockState()
        let confirmationUI = MockUI()
        let confirmationCoordinator = SafeSendCoordinator(
            database: confirmationDatabase,
            state: confirmationState,
            ui: confirmationUI,
            transactionLock: MockLock(),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let confirmationRequest = SendRequest(
            requestID: UUID(), destination: .chatID(target.id), body: "read uncertain"
        )
        #expect(try confirmationCoordinator.send(confirmationRequest).status == .unknown)
        #expect(confirmationUI.calls == 1)
        #expect(try confirmationState.sendAttempt(requestID: confirmationRequest.requestID)?.receipt.status == .unknown)
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
    var resolvedChat: Chat
    var confirmedLogID: Int64?
    var confirmationChat: ChatID?
    var confirmationBody: Data?
    var confirmationAfter: Int64?
    var confirmationCalls = 0
    var confirmationError: Error?
    var uiIdentityCount = 1

    init(chat: Chat) {
        target = chat
        resolvedChat = chat
    }
    func chats(limit: Int) throws -> [Chat] { [resolvedChat] }
    func chat(id: ChatID) throws -> Chat? { id == resolvedChat.id ? resolvedChat : nil }
    func selfChat() throws -> Chat? { resolvedChat.isSelfChat ? resolvedChat : nil }
    func chatUIIdentityCount(displayName: String) throws -> Int { uiIdentityCount }
    func messages(chatID: ChatID?, since: Date?, limit: Int) throws -> [Message] { [] }
    func maxLogID(chatID: ChatID?) throws -> Int64 { 8 }
    func messagesSince(logID: Int64, limit: Int) throws -> [Message] { [] }
    func confirmedOutgoing(chatID: ChatID, body: Data, after logID: Int64) throws -> Int64? {
        confirmationCalls += 1
        confirmationChat = chatID
        confirmationBody = body
        confirmationAfter = logID
        if let confirmationError { throw confirmationError }
        return confirmedLogID
    }
    func attachmentMetadata(logID: Int64) throws -> String? { nil }
}

private final class MockState: SendStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [UUID: StoredSendAttempt] = [:]
    private var logOwners: [Int64: UUID] = [:]
    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts.count
    }
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

private final class MockUI: KakaoSendUI, KakaoRoomPreparing,
    KakaoIdentityRecheckingSendUI, @unchecked Sendable {
    var calls = 0
    var prepareCalls = 0
    var error: SendUIError?
    var prepareError: SendUIError?
    var warmupStatus: RoomWarmupStatus = .alreadyOpen
    var onPrepare: (() throws -> Void)?
    var onSubmit: (() throws -> Void)?
    var onBeforeFinalIdentityCheck: (() throws -> Void)?
    func prepare(chat: Chat) throws -> RoomWarmupStatus {
        prepareCalls += 1
        try onPrepare?()
        if let prepareError { throw prepareError }
        return warmupStatus
    }
    func submit(chat: Chat, body: String) throws {
        try recordSubmit()
    }
    func submit(
        chat: Chat,
        body: String,
        finalIdentityCheck: () throws -> Void
    ) throws {
        calls += 1
        try onSubmit?()
        try onBeforeFinalIdentityCheck?()
        do { try finalIdentityCheck() }
        catch { throw SendUIError.preconditionFailed("final identity changed") }
        if let error { throw error }
    }
    private func recordSubmit() throws {
        calls += 1
        try onSubmit?()
        if let error { throw error }
    }
}

private final class MockLock: SendTransactionLocking, @unchecked Sendable {
    func lock() throws {}
    func unlock() {}
}

private let certifiedCompositionElements = [
    CompositionElementEvidence(role: kAXScrollAreaRole as String, identifier: "_NS:29"),
    CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:164"),
    CompositionElementEvidence(role: kAXStaticTextRole as String, identifier: "_NS:144"),
    CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:10"),
    CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:30"),
    CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:42"),
    CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:78"),
    CompositionElementEvidence(role: kAXSliderRole as String, identifier: "_NS:182"),
    CompositionElementEvidence(role: kAXScrollAreaRole as String, identifier: "_NS:47"),
]

private func cleanCompositionEvidence(
    directChildCount: Int = 18,
    identifiedDirectChildren: [CompositionElementEvidence] = certifiedCompositionElements,
    fixedLeavesAreEmpty: Bool = true,
    sliderIsClean: Bool = true,
    emptyButtonCount: Int = 8,
    nestedButtonCount: Int = 1,
    nestedButtonIsClean: Bool = true,
    composerIsOnlyChild: Bool = true,
    composerIsLeaf: Bool = true
) -> CompositionWindowEvidence {
    CompositionWindowEvidence(
        directChildCount: directChildCount,
        identifiedDirectChildren: identifiedDirectChildren,
        identifierlessButtonCount: emptyButtonCount + nestedButtonCount,
        fixedLeavesAreEmpty: fixedLeavesAreEmpty,
        sliderHasOneAnonymousLeafValueIndicator: sliderIsClean,
        emptyIdentifierlessButtonCount: emptyButtonCount,
        nestedIdentifierlessButtonCount: nestedButtonCount,
        nestedButtonHasTwoEmptyGroups: nestedButtonIsClean,
        composerScrollCount: 1,
        composerIsOnlyScrollChild: composerIsOnlyChild,
        composerIsLeaf: composerIsLeaf
    )
}
