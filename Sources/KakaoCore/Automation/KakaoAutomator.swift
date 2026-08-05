import AppKit
import ApplicationServices
import Foundation

protocol KakaoSubmitting: AnyObject, Sendable {
    /// Verify and capture the exact already-open background room without
    /// composing text or invoking any control. This phase is safe to repeat
    /// and must complete before a durable unknown receipt is reserved.
    func prepare(chat: Chat) throws

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

    private struct PreparedSend {
        let chat: Chat
        let application: NSRunningApplication
        let app: AXUIElement
        let mainWindow: AXUIElement
        let room: AXUIElement
        let table: AXUIElement
        let row: AXUIElement
        let composer: AXUIElement
        let sendControl: AXUIElement
        let windows: [AXUIElement]
        let roomChildren: [AXUIElement]
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
        guard let table = AXHelpers.verifiedSendChatListTable(mainWindow) else {
            throw AutomationError.preconditionFailed(
                "KakaoTalk's selected Chats tab and chat list could not be structurally verified"
            )
        }
        let rows = matchingRows(in: table, chat: chat)
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
        _ = try BackgroundSendSelector.preparation(
            expectedTitle: chat.displayName,
            openRooms: evidence,
            matchingRowCount: rows.count
        )
        guard rows.count == 1, let row = rows.first,
              roomWindows.count == 1, let room = roomWindows.first else {
            throw AutomationError.preconditionFailed(
                "Open the exact target room manually once, leave it open, then switch back to another app"
            )
        }
        guard AXHelpers.title(room) == chat.displayName else {
            throw AutomationError.preconditionFailed(
                "The open room title does not exactly match the destination"
            )
        }
        let composers = AXHelpers.composerCandidates(in: room)
        guard composers.count == 1, let composer = composers.first else {
            throw AutomationError.preconditionFailed("The target does not expose one exact composer")
        }
        guard AXHelpers.value(composer)?.isEmpty == true else {
            throw AutomationError.preconditionFailed("The target room contains an unsent draft")
        }
        guard AXHelpers.isCleanCompositionRoom(room, composer: composer) else {
            throw AutomationError.preconditionFailed(
                "The target room contains queued or structurally ambiguous composition state"
            )
        }
        let roomChildren = AXHelpers.children(room)
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
            sendControl: sendControl,
            windows: windows,
            roomChildren: roomChildren,
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
        let preflightControl = prepared.sendControl
        let expectedTitle = chat.displayName
        let expectedWindows = prepared.windows
        let expectedRoomChildren = prepared.roomChildren
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
            initialFrontmostProcessID: initialFrontmostProcessID
        ) else {
            throw AutomationError.preconditionFailed(
                "The exact room, row, or composer container changed before composition"
            )
        }

        var actionAttempted = false
        var composerMutationAttempted = false
        do {
            do {
                try finalIdentityCheck()
            } catch {
                throw AutomationError.preconditionFailed(
                    "The destination database identity changed after preflight"
                )
            }
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
                let cleared = AXHelpers.value(composer) == message
                    && AXHelpers.setValue(composer, "")
                    && AXHelpers.value(composer) == ""
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
                        body: "",
                        expectedWindows: expectedWindows,
                        expectedRoomChildren: expectedRoomChildren,
                        initialFrontmostProcessID: initialFrontmostProcessID
                    )
                if cleared {
                    throw AutomationError.preconditionFailed(
                        "The send precondition changed after composition; the exact draft was cleared"
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
