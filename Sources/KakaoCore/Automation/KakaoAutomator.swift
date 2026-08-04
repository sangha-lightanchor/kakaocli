import AppKit
import ApplicationServices
import Foundation

protocol KakaoSubmitting: AnyObject, Sendable {
    /// A precondition error proves that no send action was invoked and any
    /// body written by this call was safely removed. All later uncertainty is
    /// reported as `outcomeUnknown` so callers never retry the UI action.
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

    init() {}

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
        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleId
        ).filter { !$0.isTerminated }
        guard runningApps.count == 1, let runningApp = runningApps.first else {
            throw AutomationError.preconditionFailed(
                runningApps.isEmpty
                    ? "KakaoTalk is not running; foreground it manually"
                    : "Multiple KakaoTalk processes are running; the exact process is ambiguous"
            )
        }
        guard let initialFrontmostProcessID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier else {
            throw AutomationError.preconditionFailed("The foreground application could not be verified")
        }

        let processID = runningApp.processIdentifier
        let app = AXUIElementCreateApplication(processID)
        guard AXUIElementSetMessagingTimeout(app, 2.0) == .success else {
            throw AutomationError.preconditionFailed(
                "KakaoTalk Accessibility messaging could not be safely bounded"
            )
        }
        var windows = AXHelpers.windows(app)
        let mainWindows = windows.filter {
            AXHelpers.role($0) == kAXWindowRole as String
                && AXHelpers.identifier($0) == "Main Window"
        }
        guard mainWindows.count == 1, let mainWindow = mainWindows.first else {
            throw AutomationError.preconditionFailed(
                "KakaoTalk's main window is not rendered; foreground it manually"
            )
        }
        guard let table = AXHelpers.verifiedSendChatListTable(mainWindow) else {
            throw AutomationError.preconditionFailed(
                "KakaoTalk's selected Chats tab and chat list could not be structurally verified"
            )
        }

        let rows = matchingRows(in: table, chat: chat)
        // Kakao labels the self row as "My Chat"/"나와의 채팅", while the
        // opened window uses the database-resolved current-user display name.
        let expectedTitle = chat.displayName
        let roomWindows = windows.filter { !CFEqual($0, mainWindow) }
        guard roomWindows.allSatisfy(AXHelpers.isVerifiedRoomWindow) else {
            throw AutomationError.preconditionFailed(
                "A non-room or structurally ambiguous KakaoTalk window is open"
            )
        }
        let evidence = roomWindows.map { window in
            let composers = AXHelpers.composerCandidates(in: window)
            return OpenRoomEvidence(
                title: AXHelpers.title(window) ?? "",
                composerCount: composers.count,
                composerText: composers.first.flatMap(AXHelpers.value)
            )
        }
        let preparation = try BackgroundSendSelector.preparation(
            expectedTitle: expectedTitle,
            openRooms: evidence,
            matchingRowCount: rows.count
        )

        guard let row = rows.first else {
            throw AutomationError.preconditionFailed("The chat list changed during destination resolution")
        }
        let room: AXUIElement
        switch preparation {
        case .reuseExactRoom:
            guard roomWindows.count == 1, let exactRoom = roomWindows.first else {
                throw AutomationError.preconditionFailed("The exact target room changed before reuse")
            }
            room = exactRoom
        case .openExactRow:
            guard AXHelpers.selectRow(row, in: table) else {
                throw AutomationError.preconditionFailed(
                    "The exact destination row could not be verified as selected"
                )
            }
            guard foregroundProcessID() == initialFrontmostProcessID else {
                throw AutomationError.preconditionFailed(
                    "The foreground application changed while selecting the destination"
                )
            }
            guard AXHelpers.focus(table), AXHelpers.isFocused(table) else {
                throw AutomationError.preconditionFailed("The chat list did not retain focus")
            }
            guard foregroundProcessID() == initialFrontmostProcessID else {
                throw AutomationError.preconditionFailed(
                    "The foreground application changed while opening the destination"
                )
            }
            guard let openEvent = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                  let openRelease = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
                throw AutomationError.preconditionFailed("Could not create the KakaoTalk-targeted Return event")
            }

            let currentWindows = AXHelpers.windows(app)
            let currentTable = AXHelpers.verifiedSendChatListTable(mainWindow)
            let currentRows = currentTable.map { matchingRows(in: $0, chat: chat) } ?? []
            guard isOnlyExactApplication(runningApp),
                  foregroundProcessID() == initialFrontmostProcessID,
                  currentWindows.count == 1,
                  currentWindows.first.map({ CFEqual($0, mainWindow) }) == true,
                  let currentTable,
                  CFEqual(currentTable, table),
                  currentRows.count == 1,
                  currentRows.first.map({ CFEqual($0, row) }) == true,
                  AXHelpers.isExactlySelected(row, in: currentTable),
                  AXHelpers.isFocused(currentTable) else {
                throw AutomationError.preconditionFailed(
                    "Destination selection changed before the room was opened"
                )
            }
            openEvent.postToPid(processID)
            openRelease.postToPid(processID)

            room = try waitForExactRoom(
                app: app,
                mainWindow: mainWindow,
                expectedTitle: expectedTitle,
                application: runningApp,
                initialFrontmostProcessID: initialFrontmostProcessID
            )
        }

        windows = AXHelpers.windows(app)
        guard isOnlyExactApplication(runningApp),
              foregroundProcessID() == initialFrontmostProcessID,
              windows.count == 2,
              windows.contains(where: { CFEqual($0, mainWindow) }),
              windows.contains(where: { CFEqual($0, room) }),
              AXHelpers.isVerifiedRoomWindow(room) else {
            throw AutomationError.preconditionFailed("An unrelated room appeared before composition")
        }
        guard AXHelpers.title(room) == expectedTitle else {
            throw AutomationError.preconditionFailed("The target room title does not exactly match the destination")
        }

        let composers = AXHelpers.composerCandidates(in: room)
        guard composers.count == 1 else {
            throw AutomationError.preconditionFailed("The target does not expose one exact composer")
        }
        let composer = composers[0]
        guard AXHelpers.value(composer)?.isEmpty == true else {
            throw AutomationError.preconditionFailed("The target room contains an unsent draft")
        }
        guard AXHelpers.isCleanCompositionRoom(room, composer: composer) else {
            throw AutomationError.preconditionFailed(
                "The target room contains queued or structurally ambiguous composition state"
            )
        }
        let expectedWindows = windows
        let expectedRoomChildren = AXHelpers.children(room)
        let preflightControls = sendControlCandidates(in: room)
        guard preflightControls.count == 1, let preflightControl = preflightControls.first else {
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
            expectedTitle: expectedTitle,
            composer: composer,
            body: "",
            expectedWindows: expectedWindows,
            expectedRoomChildren: expectedRoomChildren,
            initialFrontmostProcessID: initialFrontmostProcessID
        ) else {
            throw AutomationError.preconditionFailed(
                "The exact room, row, or composer container changed before composition"
            )
        }

        var actionAttempted = false
        var composerMutationAttempted = false
        do {
            composerMutationAttempted = true
            guard AXHelpers.setValue(composer, message), AXHelpers.value(composer) == message else {
                throw AutomationError.preconditionFailed("The composer did not accept the exact message")
            }
            guard foregroundProcessID() == initialFrontmostProcessID else {
                throw AutomationError.preconditionFailed(
                    "The foreground application changed while composing the background message"
                )
            }

            let controls = waitForExactSendControls(
                in: room,
                initialFrontmostProcessID: initialFrontmostProcessID,
                timeout: 2
            )
            guard controls.count == 1, let control = controls.first else {
                throw AutomationError.preconditionFailed(
                    controls.isEmpty
                        ? "The exact Send control did not become enabled"
                        : "Multiple exact Send controls are exposed"
                )
            }
            guard CFEqual(control, preflightControl),
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
                    initialFrontmostProcessID: initialFrontmostProcessID
                  ) else {
                throw AutomationError.preconditionFailed("Room or composer identity changed before Send")
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
                  finalControls.first.map({ CFEqual($0, control) }) == true,
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
                      initialFrontmostProcessID: initialFrontmostProcessID
                  ) else {
                throw AutomationError.preconditionFailed("The exact Send control changed before invocation")
            }
            actionAttempted = true
            guard AXHelpers.performAction(control, kAXPressAction as String) else {
                throw AutomationError.outcomeUnknown("The exact Send control did not acknowledge its action")
            }
            guard foregroundProcessID() == initialFrontmostProcessID else {
                throw AutomationError.outcomeUnknown(
                    "The foreground application changed after Send was invoked"
                )
            }
        } catch {
            if !actionAttempted, composerMutationAttempted {
                if AXHelpers.value(composer) == message {
                    _ = AXHelpers.setValue(composer, "")
                }
                throw AutomationError.outcomeUnknown(
                    "Composer mutation began; the result is unknown and must not be retried automatically"
                )
            }
            throw error
        }
    }

    private func waitForExactRoom(
        app: AXUIElement,
        mainWindow: AXUIElement,
        expectedTitle: String,
        application: NSRunningApplication,
        initialFrontmostProcessID: pid_t
    ) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            guard isOnlyExactApplication(application),
                  foregroundProcessID() == initialFrontmostProcessID else {
                throw AutomationError.preconditionFailed(
                    "KakaoTalk or the foreground application changed while opening the room"
                )
            }
            let rooms = AXHelpers.windows(app).filter { !CFEqual($0, mainWindow) }
            if rooms.count == 1 {
                guard AXHelpers.isVerifiedRoomWindow(rooms[0]),
                      AXHelpers.title(rooms[0]) == expectedTitle else {
                    throw AutomationError.preconditionFailed("The newly opened room has the wrong title")
                }
                return rooms[0]
            }
            if rooms.count > 1 {
                throw AutomationError.preconditionFailed("Multiple rooms opened for one destination")
            }
        }
        throw AutomationError.preconditionFailed("The verified destination did not open")
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
        initialFrontmostProcessID: pid_t
    ) -> Bool {
        let windows = AXHelpers.windows(app)
        let composers = AXHelpers.composerCandidates(in: room)
        guard let currentTable = AXHelpers.verifiedSendChatListTable(mainWindow),
              CFEqual(currentTable, table) else {
            return false
        }
        let currentRows = matchingRows(in: currentTable, chat: chat)
        guard currentRows.count == 1,
              currentRows.first.map({ CFEqual($0, row) }) == true else {
            return false
        }
        do {
            try BackgroundSendSelector.verifyFinalRoom(
                expectedTitle: expectedTitle,
                expectedBody: body,
                evidence: FinalRoomEvidence(
                    applicationRunning: isOnlyExactApplication(application),
                    exactWindowSet: AXHelpers.sameElementSet(windows, expectedWindows)
                        && windows.count == 2
                        && windows.contains(where: { CFEqual($0, mainWindow) })
                        && windows.contains(where: { CFEqual($0, room) })
                        && AXHelpers.isVerifiedRoomWindow(room)
                        && AXHelpers.sameElementSet(
                            AXHelpers.children(room),
                            expectedRoomChildren
                        )
                        && AXHelpers.isCleanCompositionRoom(room, composer: composer),
                    mainWindowIdentifier: AXHelpers.identifier(mainWindow),
                    roomTitle: AXHelpers.title(room),
                    composerCount: composers.count,
                    composerIdentityMatches: composers.first.map({ CFEqual($0, composer) }) == true,
                    composerBody: AXHelpers.value(composer),
                    foregroundApplicationUnchanged: foregroundProcessID()
                        == initialFrontmostProcessID
                )
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

    private func waitForExactSendControls(
        in room: AXUIElement,
        initialFrontmostProcessID: pid_t,
        timeout: TimeInterval
    ) -> [AXUIElement] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard foregroundProcessID() == initialFrontmostProcessID else { return [] }
            let controls = exactSendControls(in: room)
            if !controls.isEmpty { return controls }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return exactSendControls(in: room)
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
