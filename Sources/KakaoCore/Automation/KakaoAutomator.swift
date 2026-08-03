import AppKit
import ApplicationServices
import Foundation

/// Fail-closed KakaoTalk send UI. This path never launches or activates the
/// app, raises a window, moves the cursor, or posts global input.
public final class KakaoAutomator {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Submit a message to a database-resolved chat. Database confirmation and
    /// durable request idempotency are handled by the caller.
    public func submit(chat: Chat, message: String) throws {
        guard !message.isEmpty else {
            throw AutomationError.preconditionFailed("Message cannot be empty")
        }
        guard let runningApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleId
        ).first else {
            throw AutomationError.preconditionFailed("KakaoTalk is not running; foreground it manually")
        }

        let processID = runningApp.processIdentifier
        let app = AXUIElementCreateApplication(processID)
        var windows = AXHelpers.windows(app)
        guard let mainWindow = windows.first(where: {
            AXHelpers.identifier($0) == "Main Window"
        }) else {
            throw AutomationError.preconditionFailed("KakaoTalk's main window is not rendered; foreground it manually")
        }
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            throw AutomationError.preconditionFailed("The rendered main window is not showing the chat list")
        }

        let rows = chat.isSelfChat
            ? AXHelpers.selfChatRows(table)
            : AXHelpers.exactChatRows(table, name: chat.displayName)
        // Kakao labels the self row as "My Chat"/"나와의 채팅", while the
        // opened window uses the database-resolved current-user display name.
        let expectedTitle = chat.displayName

        let roomWindows = windows.filter { !CFEqual($0, mainWindow) }
        let evidence = roomWindows.map { window in
            let composers = composerCandidates(in: window)
            return OpenRoomEvidence(
                title: AXHelpers.title(window) ?? "",
                composerCount: composers.count,
                composerText: composers.first.flatMap(AXHelpers.value) ?? ""
            )
        }
        let preparation = try BackgroundSendSelector.preparation(
            expectedTitle: expectedTitle,
            openRooms: evidence,
            matchingRowCount: rows.count
        )

        let room: AXUIElement
        switch preparation {
        case .reuse:
            room = roomWindows[0]
        case .openExactRow:
            guard let row = rows.first, AXHelpers.selectRow(row, in: table) else {
                throw AutomationError.preconditionFailed("The exact destination row could not be verified as selected")
            }
            guard AXHelpers.focus(table), AXHelpers.isFocused(table) else {
                throw AutomationError.preconditionFailed("The chat list did not retain focus")
            }
            guard postReturn(to: processID) else {
                throw AutomationError.preconditionFailed("Could not create the KakaoTalk-targeted Return event")
            }
            room = try waitForExactRoom(
                app: app,
                mainWindow: mainWindow,
                expectedTitle: expectedTitle
            )
            windows = AXHelpers.windows(app)
            guard windows.filter({ !CFEqual($0, mainWindow) && !CFEqual($0, room) }).isEmpty else {
                throw AutomationError.preconditionFailed("An unrelated room appeared while opening the destination")
            }
        }

        guard AXHelpers.title(room) == expectedTitle else {
            throw AutomationError.preconditionFailed("The target room title changed")
        }
        let composers = composerCandidates(in: room)
        guard composers.count == 1 else {
            throw AutomationError.preconditionFailed("The target does not expose one exact composer")
        }
        let composer = composers[0]
        guard AXHelpers.value(composer)?.isEmpty == true else {
            throw AutomationError.preconditionFailed("The target contains an unsent draft")
        }

        var actionAttempted = false
        defer {
            if !actionAttempted, AXHelpers.value(composer) == message {
                _ = AXHelpers.setValue(composer, "")
            }
        }
        guard AXHelpers.setValue(composer, message), AXHelpers.value(composer) == message else {
            throw AutomationError.preconditionFailed("The composer did not accept the exact message")
        }
        guard AXHelpers.focus(composer), AXHelpers.isFocused(composer),
              AXHelpers.value(composer) == message else {
            throw AutomationError.preconditionFailed("The exact composer did not retain focus and content")
        }
        guard AXHelpers.title(room) == expectedTitle,
              AXHelpers.windows(app).filter({ !CFEqual($0, mainWindow) }).count == 1 else {
            throw AutomationError.preconditionFailed("Room identity changed before submission")
        }

        let controls = exactSendControls(in: room)
        if controls.count == 1 {
            actionAttempted = true
            guard AXHelpers.performAction(controls[0], kAXPressAction as String) else {
                throw AutomationError.outcomeUnknown("The exact Send control did not acknowledge its action")
            }
        } else if controls.isEmpty {
            guard AXHelpers.isFocused(composer), AXHelpers.value(composer) == message else {
                throw AutomationError.preconditionFailed("Composer identity changed before Return")
            }
            guard postReturn(to: processID) else {
                throw AutomationError.preconditionFailed("Could not create the KakaoTalk-targeted Return event")
            }
            actionAttempted = true
        } else {
            throw AutomationError.preconditionFailed("Multiple exact Send controls are exposed")
        }
    }

    private func waitForExactRoom(
        app: AXUIElement,
        mainWindow: AXUIElement,
        expectedTitle: String
    ) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let rooms = AXHelpers.windows(app).filter { !CFEqual($0, mainWindow) }
            if rooms.count == 1 {
                guard AXHelpers.title(rooms[0]) == expectedTitle else {
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

    private func composerCandidates(in room: AXUIElement) -> [AXUIElement] {
        AXHelpers.findAll(room, role: "AXTextArea").filter { element in
            guard AXHelpers.isAttributeSettable(element, kAXValueAttribute as String) else { return false }
            if AXHelpers.identifier(element) == "_NS:51" { return true }
            let label = (AXHelpers.description(element) ?? "").lowercased()
            return label == "enter a message" || label == "메시지 입력"
        }
    }

    private func exactSendControls(in room: AXUIElement) -> [AXUIElement] {
        let buttons = AXHelpers.findAll(room, role: "AXButton")
        let candidates = buttons.enumerated().map { index, element in
            let labels = [AXHelpers.title(element), AXHelpers.description(element)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            return BackgroundSendControlCandidate(
                index: index,
                label: labels.count == 1 ? labels[0] : "",
                enabled: AXHelpers.boolAttribute(element, kAXEnabledAttribute as String) == true,
                supportsPress: AXHelpers.actionNames(element).contains(kAXPressAction as String)
            )
        }
        return BackgroundSendSelector.exactSendControlIndices(from: candidates).map { buttons[$0] }
    }

    private func postReturn(to processID: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else { return false }
        down.postToPid(processID)
        up.postToPid(processID)
        return true
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
