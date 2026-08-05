import AppKit
import ApplicationServices
import Foundation

protocol KakaoSubmitting: AnyObject, Sendable {
    /// Verify and capture the exact already-open background room without
    /// composing text or invoking any control. This phase is safe to repeat
    /// and must complete before a durable unknown receipt is reserved.
    func prepare(chat: Chat) throws

    /// A precondition error proves that no composer mutation or send action was
    /// attempted. Every failure after composer mutation is reported as
    /// `outcomeUnknown`, even if best-effort cleanup empties the composer.
    func submit(
        chat: Chat,
        message: String,
        finalIdentityCheck: () throws -> Void
    ) throws
}

/// Fail-closed KakaoTalk send UI. This path never launches or activates the
/// app, raises a window, moves the cursor, or posts global input.
final class KakaoAutomator: KakaoSubmitting, @unchecked Sendable {
    static let bundleId = "com.kakao.KakaoTalkMac"

    private struct RoomSnapshot {
        let room: AXUIElement
        let title: String
        let composer: AXUIElement
        let composerContainer: AXUIElement
        let children: [AXUIElement]
    }

    private struct PreparedSend {
        let chat: Chat
        let application: NSRunningApplication
        let app: AXUIElement
        let mainWindow: AXUIElement
        let room: AXUIElement
        let table: AXUIElement
        let row: AXUIElement
        let composer: AXUIElement
        let composerContainer: AXUIElement
        let sendControl: AXUIElement
        let windows: [AXUIElement]
        let roomChildren: [AXUIElement]
        let roomSnapshots: [RoomSnapshot]
        let foregroundProcessID: pid_t
    }

    private let preparedLock = NSLock()
    private var preparedSend: PreparedSend?

    init() {}

    /// Capture a send-ready room while KakaoTalk remains in the background.
    /// Closed rooms are deliberately rejected: KakaoTalk exposes no exact
    /// inactive row action that can open one without activation or global
    /// keyboard/mouse input.
    func prepare(chat: Chat) throws {
        preparedLock.lock()
        preparedSend = nil
        preparedLock.unlock()

        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleId
        ).filter { !$0.isTerminated }
        guard runningApps.count == 1, let runningApp = runningApps.first else {
            throw AutomationError.preconditionFailed(
                runningApps.isEmpty
                    ? "KakaoTalk is not running; open it manually"
                    : "Multiple KakaoTalk processes are running; the exact process is ambiguous"
            )
        }
        guard let bundleURL = runningApp.bundleURL,
              let bundle = Bundle(url: bundleURL),
              BackgroundSendSelector.isCertifiedTargetedReturnBuild(
                  version: bundle.object(
                      forInfoDictionaryKey: "CFBundleShortVersionString"
                  ) as? String,
                  build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
              ) else {
            throw AutomationError.preconditionFailed(
                "This KakaoTalk build has not passed background Return self-chat certification"
            )
        }
        guard let initialFrontmostProcessID = foregroundProcessID() else {
            throw AutomationError.preconditionFailed("The foreground application could not be verified")
        }
        guard initialFrontmostProcessID != runningApp.processIdentifier else {
            throw AutomationError.preconditionFailed(
                "KakaoTalk must be in the background before sending; switch back to another app"
            )
        }

        let app = AXUIElementCreateApplication(runningApp.processIdentifier)
        guard AXUIElementSetMessagingTimeout(app, 0.5) == .success else {
            throw AutomationError.preconditionFailed(
                "KakaoTalk Accessibility messaging could not be safely bounded"
            )
        }
        let windows = AXHelpers.windows(app)
        let mainWindows = windows.filter {
            AXHelpers.role($0) == kAXWindowRole as String
                && AXHelpers.identifier($0) == "Main Window"
        }
        guard mainWindows.count == 1, let mainWindow = mainWindows.first else {
            throw AutomationError.preconditionFailed(
                "KakaoTalk's main window is not rendered; open it manually once"
            )
        }
        guard let table = verifiedIdentityTable(in: mainWindow, chat: chat) else {
            throw AutomationError.preconditionFailed(
                "KakaoTalk's exact destination identity table could not be structurally verified"
            )
        }
        let rows = matchingRows(in: table, chat: chat)
        let roomWindows = windows.filter { !CFEqual($0, mainWindow) }
        guard roomWindows.allSatisfy(AXHelpers.isVerifiedRoomWindow) else {
            throw AutomationError.preconditionFailed(
                "A non-room or structurally ambiguous KakaoTalk window is open"
            )
        }
        var roomSnapshots: [RoomSnapshot] = []
        for roomWindow in roomWindows {
            let composers = AXHelpers.composerCandidates(in: roomWindow)
            guard let title = AXHelpers.title(roomWindow), !title.isEmpty else {
                throw AutomationError.preconditionFailed("An open room has no exact title")
            }
            guard composers.count == 1, let roomComposer = composers.first else {
                throw AutomationError.preconditionFailed(
                    "Open room '\(title)' does not expose one exact composer"
                )
            }
            guard let roomComposerContainer = AXHelpers.composerContainer(in: roomWindow),
                  AXHelpers.children(roomComposerContainer).count == 1,
                  AXHelpers.children(roomComposerContainer).first.map({
                      CFEqual($0, roomComposer)
                  }) == true else {
                throw AutomationError.preconditionFailed(
                    "Open room '\(title)' has an ambiguous composer container"
                )
            }
            guard AXHelpers.value(roomComposer) == "" else {
                throw AutomationError.preconditionFailed(
                    "Open room '\(title)' contains a draft"
                )
            }
            guard AXHelpers.isCleanCompositionRoom(
                roomWindow,
                composer: roomComposer
            ) else {
                throw AutomationError.preconditionFailed(
                    "Open room '\(title)' has uncertified composition chrome"
                )
            }
            roomSnapshots.append(
                RoomSnapshot(
                    room: roomWindow,
                    title: title,
                    composer: roomComposer,
                    composerContainer: roomComposerContainer,
                    children: AXHelpers.children(roomWindow)
                )
            )
        }
        let evidence = roomSnapshots.map {
            OpenRoomEvidence(title: $0.title, composerCount: 1, composerText: "")
        }
        _ = try BackgroundSendSelector.preparation(
            expectedTitle: chat.displayName,
            openRooms: evidence,
            matchingRowCount: rows.count
        )
        let targetSnapshots = roomSnapshots.filter { $0.title == chat.displayName }
        guard rows.count == 1, let row = rows.first,
              targetSnapshots.count == 1, let targetSnapshot = targetSnapshots.first else {
            throw AutomationError.preconditionFailed(
                "Open the exact target room manually once, leave it open, then switch back to another app"
            )
        }
        let room = targetSnapshot.room
        guard AXHelpers.title(room) == chat.displayName else {
            throw AutomationError.preconditionFailed(
                "The open room title does not exactly match the destination"
            )
        }
        let composer = targetSnapshot.composer
        let composerContainer = targetSnapshot.composerContainer
        let roomChildren = targetSnapshot.children
        let controls = sendControlCandidates(in: room)
        guard controls.count == 1, let sendControl = controls.first else {
            throw AutomationError.preconditionFailed(
                "The exact target room does not expose one unambiguous Send control"
            )
        }
        guard finalRoomIsVerified(
            application: runningApp,
            app: app,
            mainWindow: mainWindow,
            room: room,
            table: table,
            row: row,
            chat: chat,
            expectedTitle: chat.displayName,
            composer: composer,
            body: "",
            expectedWindows: windows,
            expectedRoomChildren: roomChildren,
            expectedComposerContainer: composerContainer,
            roomSnapshots: roomSnapshots,
            composerIdentityPolicy: .exactPreMutationComposer,
            initialFrontmostProcessID: initialFrontmostProcessID
        ) else {
            throw AutomationError.preconditionFailed(
                "The exact room, row, or composer container changed during preflight"
            )
        }

        preparedLock.lock()
        preparedSend = PreparedSend(
            chat: chat,
            application: runningApp,
            app: app,
            mainWindow: mainWindow,
            room: room,
            table: table,
            row: row,
            composer: composer,
            composerContainer: composerContainer,
            sendControl: sendControl,
            windows: windows,
            roomChildren: roomChildren,
            roomSnapshots: roomSnapshots,
            foregroundProcessID: initialFrontmostProcessID
        )
        preparedLock.unlock()
    }

    /// Submit a message to a database-resolved chat. Database confirmation and
    /// durable request idempotency are handled by the caller.
    func submit(
        chat: Chat,
        message: String,
        finalIdentityCheck: () throws -> Void
    ) throws {
        guard !message.isEmpty else {
            throw AutomationError.preconditionFailed("Message cannot be empty")
        }
        preparedLock.lock()
        let prepared = preparedSend
        preparedSend = nil
        preparedLock.unlock()
        guard let prepared,
              prepared.chat.id == chat.id,
              prepared.chat.type == chat.type,
              prepared.chat.displayName == chat.displayName,
              prepared.chat.memberCount == chat.memberCount,
              prepared.chat.isSelfChat == chat.isSelfChat else {
            throw AutomationError.preconditionFailed(
                "The exact target room was not successfully preflighted"
            )
        }
        let runningApp = prepared.application
        let app = prepared.app
        let mainWindow = prepared.mainWindow
        let room = prepared.room
        let table = prepared.table
        let row = prepared.row
        let composer = prepared.composer
        let composerContainer = prepared.composerContainer
        let preflightControl = prepared.sendControl
        let expectedTitle = chat.displayName
        let expectedWindows = prepared.windows
        let expectedRoomChildren = prepared.roomChildren
        let roomSnapshots = prepared.roomSnapshots
        let initialFrontmostProcessID = prepared.foregroundProcessID

        guard finalRoomIsVerified(
            application: runningApp,
            app: app,
            mainWindow: mainWindow,
            room: room,
            table: table,
            row: row,
            chat: chat,
            expectedTitle: expectedTitle,
            composer: composer,
            body: "",
            expectedWindows: expectedWindows,
            expectedRoomChildren: expectedRoomChildren,
            expectedComposerContainer: composerContainer,
            roomSnapshots: roomSnapshots,
            composerIdentityPolicy: .exactPreMutationComposer,
            initialFrontmostProcessID: initialFrontmostProcessID
        ) else {
            throw AutomationError.preconditionFailed(
                "The exact room, row, or composer container changed before composition"
            )
        }

        var actionAttempted = false
        var composerMutationAttempted = false
        do {
            guard makeTargetComposerFirstResponder(
                app: app,
                room: room,
                composer: composer,
                initialFrontmostProcessID: initialFrontmostProcessID
            ), exactFocusedComposer(
                app: app,
                in: room,
                body: "",
                expectedRoomChildren: expectedRoomChildren,
                expectedComposerContainer: composerContainer
            ) != nil else {
                throw AutomationError.preconditionFailed(
                    "The exact target composer could not become Kakao's first responder in the background"
                )
            }
            do {
                try finalIdentityCheck()
            } catch {
                throw AutomationError.preconditionFailed(
                    "The destination database identity changed after preflight"
                )
            }
            composerMutationAttempted = true
            guard AXHelpers.setValue(composer, message) else {
                throw AutomationError.preconditionFailed("The composer did not accept the exact message")
            }
            guard foregroundProcessID() == initialFrontmostProcessID else {
                throw AutomationError.preconditionFailed(
                    "The foreground application changed while composing the background message"
                )
            }

            guard let control = waitForStableSendControl(
                in: room,
                expectedControl: preflightControl,
                initialFrontmostProcessID: initialFrontmostProcessID,
                timeout: 2,
                isStable: {
                    finalRoomIsVerified(
                        application: runningApp,
                        app: app,
                        mainWindow: mainWindow,
                        room: room,
                        table: table,
                        row: row,
                        chat: chat,
                        expectedTitle: expectedTitle,
                        composer: composer,
                        body: message,
                        expectedWindows: expectedWindows,
                        expectedRoomChildren: expectedRoomChildren,
                        expectedComposerContainer: composerContainer,
                        roomSnapshots: roomSnapshots,
                        composerIdentityPolicy: .structurallyAnchoredAfterMutation,
                        initialFrontmostProcessID: initialFrontmostProcessID
                    )
                }
            ) else {
                throw AutomationError.preconditionFailed(
                    "The exact composed room and Send control did not stabilize"
                )
            }
            do {
                try finalIdentityCheck()
            } catch {
                throw AutomationError.preconditionFailed(
                    "The destination database identity changed before Send"
                )
            }
            let finalControls = exactSendControls(in: room)
            guard finalControls.count == 1,
                  finalControls.first.map({ CFEqual($0, control) }) == true else {
                throw AutomationError.preconditionFailed(
                    "The exact Send control changed before invocation"
                )
            }
            guard finalRoomIsVerified(
                      application: runningApp,
                      app: app,
                      mainWindow: mainWindow,
                      room: room,
                      table: table,
                      row: row,
                      chat: chat,
                      expectedTitle: expectedTitle,
                      composer: composer,
                      body: message,
                      expectedWindows: expectedWindows,
                      expectedRoomChildren: expectedRoomChildren,
                      expectedComposerContainer: composerContainer,
                      roomSnapshots: roomSnapshots,
                      composerIdentityPolicy: .structurallyAnchoredAfterMutation,
                      initialFrontmostProcessID: initialFrontmostProcessID
                  ) else {
                throw AutomationError.preconditionFailed(
                    "Room or composer identity changed at the final invocation boundary"
                )
            }
            guard let focusedComposer = exactFocusedComposer(
                app: app,
                in: room,
                body: message,
                expectedRoomChildren: expectedRoomChildren,
                expectedComposerContainer: composerContainer
            ) else {
                throw AutomationError.preconditionFailed(
                    "The exact structurally anchored composer is not focused for Kakao-only Return"
                )
            }
            guard AXHelpers.boolAttribute(room, kAXMainAttribute as String) == true else {
                throw AutomationError.preconditionFailed(
                    "The exact target room is not Kakao's internal main window"
                )
            }
            guard let returnEvents = AXHelpers.makeTargetedReturnEvents() else {
                throw AutomationError.preconditionFailed(
                    "The Kakao-only Return event could not be created"
                )
            }
            let invocationControls = exactSendControls(in: room)
            guard invocationControls.count == 1,
                  invocationControls.first.map({ CFEqual($0, control) }) == true,
                  AXHelpers.boolAttribute(room, kAXMainAttribute as String) == true,
                  exactFocusedComposer(
                app: app,
                in: room,
                body: message,
                expectedRoomChildren: expectedRoomChildren,
                expectedComposerContainer: composerContainer
            ).map({ CFEqual($0, focusedComposer) }) == true,
                  foregroundProcessID() == initialFrontmostProcessID else {
                throw AutomationError.preconditionFailed(
                    "Control, room, composer focus, or foreground identity changed before Kakao-only Return"
                )
            }
            actionAttempted = true
            AXHelpers.postTargetedReturn(returnEvents, to: runningApp.processIdentifier)
            guard foregroundProcessID() == initialFrontmostProcessID else {
                throw AutomationError.outcomeUnknown(
                    "The foreground application changed after Kakao-only Return was posted"
                )
            }
            guard waitForStableCondition(
                initialFrontmostProcessID: initialFrontmostProcessID,
                timeout: 2,
                {
                    finalRoomIsVerified(
                        application: runningApp,
                        app: app,
                        mainWindow: mainWindow,
                        room: room,
                        table: table,
                        row: row,
                        chat: chat,
                        expectedTitle: expectedTitle,
                        composer: composer,
                        body: "",
                        expectedWindows: expectedWindows,
                        expectedRoomChildren: expectedRoomChildren,
                        expectedComposerContainer: composerContainer,
                        roomSnapshots: roomSnapshots,
                        composerIdentityPolicy: .structurallyAnchoredAfterMutation,
                        initialFrontmostProcessID: initialFrontmostProcessID
                    )
                }
            ) else {
                throw AutomationError.outcomeUnknown(
                    "Kakao-only Return was posted but an exact empty composer was not observed"
                )
            }
        } catch {
            if !actionAttempted, composerMutationAttempted {
                let currentComposer = exactFocusedComposer(
                    app: app,
                    in: room,
                    body: message,
                    expectedRoomChildren: expectedRoomChildren,
                    expectedComposerContainer: composerContainer
                )
                let canClearExactDraft = currentComposer != nil
                    && foregroundProcessID() == initialFrontmostProcessID
                    && finalRoomIsVerified(
                        application: runningApp,
                        app: app,
                        mainWindow: mainWindow,
                        room: room,
                        table: table,
                        row: row,
                        chat: chat,
                        expectedTitle: expectedTitle,
                        composer: composer,
                        body: message,
                        expectedWindows: expectedWindows,
                        expectedRoomChildren: expectedRoomChildren,
                        expectedComposerContainer: composerContainer,
                        roomSnapshots: roomSnapshots,
                        composerIdentityPolicy: .structurallyAnchoredAfterMutation,
                        initialFrontmostProcessID: initialFrontmostProcessID
                    )
                let clearMutationSucceeded = canClearExactDraft
                    && foregroundProcessID() == initialFrontmostProcessID
                    && currentComposer.map { AXHelpers.setValue($0, "") } == true
                let cleared = clearMutationSucceeded
                    && waitForStableCondition(
                        initialFrontmostProcessID: initialFrontmostProcessID,
                        timeout: 2
                    ) {
                        finalRoomIsVerified(
                        application: runningApp,
                        app: app,
                        mainWindow: mainWindow,
                        room: room,
                        table: table,
                        row: row,
                        chat: chat,
                        expectedTitle: expectedTitle,
                        composer: composer,
                        body: "",
                        expectedWindows: expectedWindows,
                        expectedRoomChildren: expectedRoomChildren,
                        expectedComposerContainer: composerContainer,
                        roomSnapshots: roomSnapshots,
                        composerIdentityPolicy: .structurallyAnchoredAfterMutation,
                        initialFrontmostProcessID: initialFrontmostProcessID
                    )
                    }
                if cleared {
                    throw AutomationError.outcomeUnknown(
                        "Composer mutation began; the exact draft was cleared, but delivery remains unknown and must not be retried automatically"
                    )
                }
                throw AutomationError.outcomeUnknown(
                    "Composer mutation began; the result is unknown and must not be retried automatically"
                )
            }
            throw error
        }
    }

    private func matchingRows(in table: AXUIElement, chat: Chat) -> [AXUIElement] {
        chat.isSelfChat
            ? AXHelpers.selfChatRows(table)
            : AXHelpers.exactChatRows(table, name: chat.displayName)
    }

    private func finalRoomIsVerified(
        application: NSRunningApplication,
        app: AXUIElement,
        mainWindow: AXUIElement,
        room: AXUIElement,
        table: AXUIElement,
        row: AXUIElement,
        chat: Chat,
        expectedTitle: String,
        composer: AXUIElement,
        body: String,
        expectedWindows: [AXUIElement],
        expectedRoomChildren: [AXUIElement],
        expectedComposerContainer: AXUIElement,
        roomSnapshots: [RoomSnapshot],
        composerIdentityPolicy: ComposerIdentityPolicy,
        initialFrontmostProcessID: pid_t
    ) -> Bool {
        let windows = AXHelpers.windows(app)
        let composers = AXHelpers.composerCandidates(in: room)
        let currentComposer = composers.count == 1 ? composers[0] : nil
        let currentComposerContainer = AXHelpers.composerContainer(in: room)
        guard let currentTable = verifiedIdentityTable(in: mainWindow, chat: chat),
              CFEqual(currentTable, table) else {
            return false
        }
        let currentRows = matchingRows(in: currentTable, chat: chat)
        guard currentRows.count == 1,
              currentRows.first.map({ CFEqual($0, row) }) == true else {
            return false
        }
        let targetSnapshots = roomSnapshots.filter { CFEqual($0.room, room) }
        let unrelatedSnapshots = roomSnapshots.filter { !CFEqual($0.room, room) }
        let unrelatedRoomsAreStable = unrelatedSnapshots.allSatisfy { snapshot in
            let currentComposers = AXHelpers.composerCandidates(in: snapshot.room)
            let currentContainer = AXHelpers.composerContainer(in: snapshot.room)
            return AXHelpers.isVerifiedRoomWindow(snapshot.room)
                && AXHelpers.title(snapshot.room) == snapshot.title
                && AXHelpers.sameElementOrder(
                    AXHelpers.children(snapshot.room),
                    snapshot.children
                )
                && currentContainer.map {
                    CFEqual($0, snapshot.composerContainer)
                } == true
                && currentComposers.count == 1
                && currentComposers.first.map {
                    CFEqual($0, snapshot.composer)
                } == true
                && currentComposers.first.flatMap(AXHelpers.value) == ""
                && currentComposers.first.map {
                    AXHelpers.isCleanCompositionRoom(snapshot.room, composer: $0)
                } == true
                && currentComposers.first.map(AXHelpers.isFocused) == false
        }
        let exactWindowSet = AXHelpers.sameElementSet(windows, expectedWindows)
            && windows.count == expectedWindows.count
            && windows.count == roomSnapshots.count + 1
            && targetSnapshots.count == 1
            && unrelatedRoomsAreStable
            && windows.contains(where: { CFEqual($0, mainWindow) })
            && windows.contains(where: { CFEqual($0, room) })
            && AXHelpers.isVerifiedRoomWindow(room)
            && AXHelpers.sameElementOrder(
                AXHelpers.children(room),
                expectedRoomChildren
            )
            && currentComposer.map {
                AXHelpers.isCleanCompositionRoom(room, composer: $0)
            } == true
        let evidence = FinalRoomEvidence(
            applicationRunning: isOnlyExactApplication(application),
            exactWindowSet: exactWindowSet,
            mainWindowIdentifier: AXHelpers.identifier(mainWindow),
            roomTitle: AXHelpers.title(room),
            composerCount: composers.count,
            composerIdentityMatches: currentComposer.map({ CFEqual($0, composer) }) == true,
            composerContainerIdentityMatches: currentComposerContainer.map {
                CFEqual($0, expectedComposerContainer)
            } == true,
            composerBody: currentComposer.flatMap(AXHelpers.value),
            foregroundApplicationUnchanged: foregroundProcessID()
                == initialFrontmostProcessID
        )
        do {
            try BackgroundSendSelector.verifyFinalRoom(
                expectedTitle: expectedTitle,
                expectedBody: body,
                composerIdentityPolicy: composerIdentityPolicy,
                evidence: evidence
            )
            return true
        } catch {
            return false
        }
    }

    private func isOnlyExactApplication(_ expected: NSRunningApplication) -> Bool {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleId
        ).filter { !$0.isTerminated }
        guard running.count == 1, let current = running.first else { return false }
        return current.processIdentifier == expected.processIdentifier
            && current.bundleIdentifier == expected.bundleIdentifier
            && current.launchDate == expected.launchDate
    }

    private func foregroundProcessID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func verifiedIdentityTable(in mainWindow: AXUIElement, chat: Chat) -> AXUIElement? {
        if chat.isSelfChat {
            return AXHelpers.verifiedSendChatListTable(mainWindow)
                ?? AXHelpers.verifiedSelfIdentityTable(mainWindow)
        }
        return AXHelpers.verifiedSendChatListTable(mainWindow)
    }

    private func makeTargetComposerFirstResponder(
        app: AXUIElement,
        room: AXUIElement,
        composer: AXUIElement,
        initialFrontmostProcessID: pid_t
    ) -> Bool {
        guard foregroundProcessID() == initialFrontmostProcessID,
              AXHelpers.setMainWindow(room),
              foregroundProcessID() == initialFrontmostProcessID,
              AXHelpers.boolAttribute(room, kAXMainAttribute as String) == true,
              AXHelpers.setFocused(composer),
              foregroundProcessID() == initialFrontmostProcessID,
              AXHelpers.elementAttribute(
                  app,
                  kAXFocusedWindowAttribute as String
              ).map({ CFEqual($0, room) }) == true,
              AXHelpers.elementAttribute(
                  app,
                  kAXFocusedUIElementAttribute as String
              ).map({ CFEqual($0, composer) }) == true,
              AXHelpers.isFocused(composer) else { return false }
        return true
    }

    private func exactFocusedComposer(
        app: AXUIElement,
        in room: AXUIElement,
        body: String,
        expectedRoomChildren: [AXUIElement],
        expectedComposerContainer: AXUIElement
    ) -> AXUIElement? {
        let roomChildren = AXHelpers.children(room)
        let container = AXHelpers.composerContainer(in: room)
        let composers = AXHelpers.composerCandidates(in: room)
        guard composers.count == 1, let composer = composers.first else { return nil }
        let focusedWindow = AXHelpers.elementAttribute(
            app,
            kAXFocusedWindowAttribute as String
        )
        let focusedUIElement = AXHelpers.elementAttribute(
            app,
            kAXFocusedUIElementAttribute as String
        )
        guard BackgroundSendSelector.isExactTargetFirstResponder(
            expectedBody: body,
            evidence: FocusedComposerEvidence(
                roomChildrenMatch: AXHelpers.sameElementOrder(
                    roomChildren,
                    expectedRoomChildren
                ),
                composerContainerMatches: container.map {
                    CFEqual($0, expectedComposerContainer)
                } == true,
                composerCount: composers.count,
                compositionStructureCertified: AXHelpers.isCleanCompositionRoom(
                    room,
                    composer: composer
                ),
                composerBody: AXHelpers.value(composer),
                roomIsMain: AXHelpers.boolAttribute(
                    room,
                    kAXMainAttribute as String
                ) == true,
                focusedWindowMatchesRoom: focusedWindow.map {
                    CFEqual($0, room)
                } == true,
                focusedUIElementMatchesComposer: focusedUIElement.map {
                    CFEqual($0, composer)
                } == true,
                composerIsFocused: AXHelpers.isFocused(composer)
            )
        ) else { return nil }
        return composer
    }

    private func waitForStableSendControl(
        in room: AXUIElement,
        expectedControl: AXUIElement,
        initialFrontmostProcessID: pid_t,
        timeout: TimeInterval,
        isStable: () -> Bool
    ) -> AXUIElement? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard foregroundProcessID() == initialFrontmostProcessID else { return nil }
            let controls = exactSendControls(in: room)
            if controls.count > 1 { return nil }
            if let control = controls.first {
                guard CFEqual(control, expectedControl) else { return nil }
                if isStable() { return control }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private func waitForStableCondition(
        initialFrontmostProcessID: pid_t,
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard foregroundProcessID() == initialFrontmostProcessID else { return false }
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func sendControlCandidates(in room: AXUIElement) -> [AXUIElement] {
        controls(in: room, enabledOnly: false)
    }

    private func exactSendControls(in room: AXUIElement) -> [AXUIElement] {
        controls(in: room, enabledOnly: true)
    }

    private func controls(in room: AXUIElement, enabledOnly: Bool) -> [AXUIElement] {
        let directChildren = AXHelpers.children(room)
        let candidates = directChildren.enumerated().map { index, element in
            let accepted = Set(["send", "전송"])
            let labels = [AXHelpers.title(element), AXHelpers.description(element)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let matchingLabels = Set(labels.filter(accepted.contains))
            return BackgroundSendControlCandidate(
                index: index,
                label: matchingLabels.count == 1 ? matchingLabels.first! : "",
                role: AXHelpers.role(element),
                identifier: AXHelpers.identifier(element),
                hidden: AXHelpers.boolAttribute(element, kAXHiddenAttribute as String),
                frameContained: AXHelpers.hasContainedFrame(element, in: room),
                directChild: true,
                enabled: AXHelpers.boolAttribute(element, kAXEnabledAttribute as String) == true,
                supportsPress: AXHelpers.actionNames(element).contains(kAXPressAction as String)
            )
        }
        let indices = enabledOnly
            ? BackgroundSendSelector.exactSendControlIndices(from: candidates)
            : BackgroundSendSelector.sendControlCandidateIndices(from: candidates)
        return indices.map { directChildren[$0] }
    }
}

public enum AutomationError: Error, CustomStringConvertible {
    // Retained for non-send legacy commands such as harvest.
    case noWindows
    case chatNotFound(String)
    case preconditionFailed(String)
    case outcomeUnknown(String)

    public var description: String {
        switch self {
        case .noWindows: return "No KakaoTalk windows found"
        case .chatNotFound(let name): return "Chat not found: \(name)"
        case .preconditionFailed(let message): return "Send precondition failed: \(message)"
        case .outcomeUnknown(let message): return "Send outcome unknown: \(message)"
        }
    }
}
