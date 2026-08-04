import AppKit
import ApplicationServices
import Foundation

public enum SendUIError: Error, CustomStringConvertible, Equatable {
    case preconditionFailed(String)
    case outcomeUnknown(String)

    public var description: String {
        switch self {
        case .preconditionFailed(let message), .outcomeUnknown(let message): return message
        }
    }
}

public protocol KakaoSendUI: AnyObject, Sendable {
    /// Submit a fully preflighted message. Precondition errors prove no send
    /// action occurred. Any uncertainty after invoking a control is reported as
    /// `outcomeUnknown` so callers never retry automatically.
    func submit(chat: Chat, body: String) throws
}

public struct OpenRoomEvidence: Sendable, Equatable {
    public let title: String
    public let composerCount: Int
    public let composerText: String

    public init(title: String, composerCount: Int, composerText: String) {
        self.title = title
        self.composerCount = composerCount
        self.composerText = composerText
    }
}

public enum RoomPreparation: Sendable, Equatable {
    case reuse
    case openExactRow
}

/// Pure fail-closed decisions used by both the real transport and unit tests.
public enum SendUIValidator {
    public static func preparation(
        expectedTitle: String,
        openRooms: [OpenRoomEvidence],
        matchingRowCount: Int
    ) throws -> RoomPreparation {
        if !openRooms.isEmpty {
            guard openRooms.count == 1 else {
                throw SendUIError.preconditionFailed("Multiple chat rooms are open")
            }
            let room = openRooms[0]
            guard room.title == expectedTitle else {
                throw SendUIError.preconditionFailed("An unrelated chat room is open")
            }
            guard room.composerCount == 1 else {
                throw SendUIError.preconditionFailed("The target room composer is ambiguous")
            }
            guard room.composerText.isEmpty else {
                throw SendUIError.preconditionFailed("The target room contains an unsent draft")
            }
            return .reuse
        }

        guard matchingRowCount == 1 else {
            let message = matchingRowCount == 0
                ? "The exact destination row is not visible"
                : "The destination label matches multiple UI rows"
            throw SendUIError.preconditionFailed(message)
        }
        return .openExactRow
    }
}

/// Safe UI transport. It operates only on an already-running KakaoTalk process
/// with a rendered main window. The only keyboard event is Return delivered to
/// KakaoTalk's PID after the exact composer is focused and reverified.
public final class SafeKakaoSender: KakaoSendUI, @unchecked Sendable {
    public static let bundleIdentifier = "com.kakao.KakaoTalkMac"

    public init() {}

    public func submit(chat: Chat, body: String) throws {
        guard !body.isEmpty else {
            throw SendUIError.preconditionFailed("Message body cannot be empty")
        }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).first else {
            throw SendUIError.preconditionFailed("KakaoTalk is not running; foreground it manually")
        }
        let processID = application.processIdentifier
        let appElement = AXUIElementCreateApplication(processID)
        var windows = AXHelpers.windows(appElement)
        guard let mainWindow = windows.first(where: {
            AXHelpers.identifier($0) == "Main Window"
        }) else {
            throw SendUIError.preconditionFailed("KakaoTalk's main window is not rendered; foreground it manually")
        }

        let roomWindows = windows.filter { !CFEqual($0, mainWindow) }
        let rows: [AXUIElement]
        if let table = AXHelpers.chatList(in: mainWindow) {
            rows = AXHelpers.rows(in: table).filter { row in
                chat.isSelfChat ? AXHelpers.isSelfRow(row) : AXHelpers.exactName(in: row) == chat.displayName
            }
        } else {
            rows = []
        }
        // For self-chat, row identity is proven by Kakao's unique self badge;
        // the room title is the database-resolved current-user display name,
        // not the row's localized "My Chat" label.
        let expectedTitle = chat.displayName
        let roomEvidence = roomWindows.map { window in
            let composers = composerCandidates(in: window)
            return OpenRoomEvidence(
                title: AXHelpers.title(window) ?? "",
                composerCount: composers.count,
                composerText: composers.first.flatMap(AXHelpers.value) ?? ""
            )
        }

        let preparation = try SendUIValidator.preparation(
            expectedTitle: expectedTitle,
            openRooms: roomEvidence,
            matchingRowCount: rows.count
        )

        let room: AXUIElement
        switch preparation {
        case .reuse:
            room = roomWindows[0]
        case .openExactRow:
            guard let table = AXHelpers.chatList(in: mainWindow), let row = rows.first else {
                throw SendUIError.preconditionFailed("The chat list changed during destination resolution")
            }
            guard AXHelpers.selectExactly(row, in: table) else {
                throw SendUIError.preconditionFailed("The exact destination row could not be verified as selected")
            }
            guard AXHelpers.focus(table), AXHelpers.isFocused(table) else {
                throw SendUIError.preconditionFailed("KakaoTalk did not retain focus on the verified chat list")
            }
            try postReturn(to: processID, preconditionMessage: "The verified destination row could not be opened")
            room = try waitForExactRoom(appElement: appElement, mainWindow: mainWindow, title: expectedTitle)
            windows = AXHelpers.windows(appElement)
            let unrelated = windows.filter { !CFEqual($0, mainWindow) && !CFEqual($0, room) }
            guard unrelated.isEmpty else {
                throw SendUIError.preconditionFailed("An unrelated room appeared while opening the destination")
            }
        }

        guard AXHelpers.title(room) == expectedTitle else {
            throw SendUIError.preconditionFailed("The opened room title does not exactly match the destination")
        }
        let composers = composerCandidates(in: room)
        guard composers.count == 1 else {
            throw SendUIError.preconditionFailed("The target room does not expose exactly one verified composer")
        }
        let composer = composers[0]
        guard AXHelpers.value(composer)?.isEmpty == true else {
            throw SendUIError.preconditionFailed("The target room contains an unsent draft")
        }

        var actionAttempted = false
        defer {
            if !actionAttempted, AXHelpers.value(composer) == body {
                _ = AXHelpers.setValue(composer, "")
            }
        }
        guard AXHelpers.setValue(composer, body), AXHelpers.value(composer) == body else {
            throw SendUIError.preconditionFailed("KakaoTalk did not accept the exact message bytes")
        }
        guard AXHelpers.focus(composer), AXHelpers.isFocused(composer), AXHelpers.value(composer) == body else {
            throw SendUIError.preconditionFailed("The verified composer did not retain focus and content")
        }

        let controls = exactSendControls(in: room)
        if controls.count == 1 {
            actionAttempted = true
            guard AXHelpers.perform(controls[0], kAXPressAction as String) else {
                throw SendUIError.outcomeUnknown("KakaoTalk did not acknowledge the exact Send control")
            }
        } else if controls.isEmpty {
            guard AXHelpers.isFocused(composer), AXHelpers.value(composer) == body else {
                throw SendUIError.preconditionFailed("Composer identity changed before Return")
            }
            actionAttempted = true
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                  let release = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
                throw SendUIError.outcomeUnknown("The Kakao-only Return event could not be created")
            }
            event.postToPid(processID)
            release.postToPid(processID)
        } else {
            throw SendUIError.preconditionFailed("Multiple exact Send controls are exposed")
        }
    }

    private func waitForExactRoom(
        appElement: AXUIElement,
        mainWindow: AXUIElement,
        title: String
    ) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let rooms = AXHelpers.windows(appElement).filter { !CFEqual($0, mainWindow) }
            if rooms.count == 1 {
                guard AXHelpers.title(rooms[0]) == title else {
                    throw SendUIError.preconditionFailed("The newly opened room has the wrong title")
                }
                return rooms[0]
            }
            if rooms.count > 1 {
                throw SendUIError.preconditionFailed("Multiple rooms opened for one destination")
            }
        }
        throw SendUIError.preconditionFailed("The verified destination room did not open")
    }

    private func composerCandidates(in room: AXUIElement) -> [AXUIElement] {
        AXHelpers.descendants(room) { element in
            guard AXHelpers.role(element) == kAXTextAreaRole as String,
                  AXHelpers.isSettable(element, kAXValueAttribute as String) else { return false }
            if AXHelpers.identifier(element) == "_NS:51" { return true }
            let label = (AXHelpers.description(element) ?? "").lowercased()
            return label == "enter a message" || label == "메시지 입력"
        }
    }

    private func exactSendControls(in room: AXUIElement) -> [AXUIElement] {
        let accepted = Set(["send", "전송"])
        return AXHelpers.descendants(room) { element in
            guard AXHelpers.role(element) == kAXButtonRole as String,
                  AXHelpers.bool(element, kAXEnabledAttribute as String) == true,
                  AXHelpers.actions(element).contains(kAXPressAction as String) else { return false }
            let labels = [AXHelpers.title(element), AXHelpers.description(element)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return labels.contains { accepted.contains($0) }
        }
    }

    private func postReturn(to processID: pid_t, preconditionMessage: String) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
              let release = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
            throw SendUIError.preconditionFailed(preconditionMessage)
        }
        event.postToPid(processID)
        release.postToPid(processID)
    }
}
