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

public struct NavigationControlEvidence: Sendable, Equatable {
    public let role: String?
    public let identifier: String?
    public let title: String?
    public let description: String?
    /// `nil` means KakaoTalk does not expose either AXSelected or a boolean
    /// AXValue for this control. It is distinct from an explicit `false`.
    public let selected: Bool?
    public let enabled: Bool?

    public init(
        role: String?,
        identifier: String?,
        title: String?,
        description: String?,
        selected: Bool?,
        enabled: Bool? = nil
    ) {
        self.role = role
        self.identifier = identifier
        self.title = title
        self.description = description
        self.selected = selected
        self.enabled = enabled
    }
}

public struct ChatRowStructureEvidence: Sendable, Equatable {
    public let nonemptyNameLabelCount: Int
    public let profileControlCount: Int
    public let metadataLabelCount: Int
    public let messagePreviewCount: Int

    public init(
        nonemptyNameLabelCount: Int,
        profileControlCount: Int,
        metadataLabelCount: Int,
        messagePreviewCount: Int
    ) {
        self.nonemptyNameLabelCount = nonemptyNameLabelCount
        self.profileControlCount = profileControlCount
        self.metadataLabelCount = metadataLabelCount
        self.messagePreviewCount = messagePreviewCount
    }
}

public struct FinalRoomEvidence: Sendable, Equatable {
    public let applicationRunning: Bool
    public let exactWindowSet: Bool
    public let mainWindowIdentifier: String?
    public let roomTitle: String?
    public let composerCount: Int
    public let composerIdentityMatches: Bool
    public let composerBody: String?
    public let frontmostApplicationUnchanged: Bool

    public init(
        applicationRunning: Bool,
        exactWindowSet: Bool,
        mainWindowIdentifier: String?,
        roomTitle: String?,
        composerCount: Int,
        composerIdentityMatches: Bool,
        composerBody: String?,
        frontmostApplicationUnchanged: Bool
    ) {
        self.applicationRunning = applicationRunning
        self.exactWindowSet = exactWindowSet
        self.mainWindowIdentifier = mainWindowIdentifier
        self.roomTitle = roomTitle
        self.composerCount = composerCount
        self.composerIdentityMatches = composerIdentityMatches
        self.composerBody = composerBody
        self.frontmostApplicationUnchanged = frontmostApplicationUnchanged
    }
}

/// Pure fail-closed decisions used by both the real transport and unit tests.
public enum SendUIValidator {
    public static func isSelectedChatsNavigation(_ evidence: NavigationControlEvidence) -> Bool {
        guard evidence.selected == true else { return false }
        if evidence.role == kAXCheckBoxRole as String,
           evidence.identifier == "chatrooms" {
            return true
        }
        guard evidence.role == kAXButtonRole as String
                || evidence.role == kAXRadioButtonRole as String else { return false }
        let acceptedLabels = Set(["chat", "chats", "채팅"])
        let labels = [evidence.title, evidence.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return labels.contains(where: acceptedLabels.contains)
    }

    public static func isStatelessChatsNavigationSet(
        _ evidence: [NavigationControlEvidence]
    ) -> Bool {
        let knownIdentifiers = Set(["friends", "chatrooms", "more"])
        let known = evidence.filter { item in
            item.identifier.map(knownIdentifiers.contains) == true
        }
        guard known.count == knownIdentifiers.count else { return false }
        for identifier in knownIdentifiers {
            let matches = known.filter { $0.identifier == identifier }
            guard matches.count == 1,
                  let control = matches.first,
                  control.role == kAXButtonRole as String,
                  control.selected == nil,
                  control.enabled == true else {
                return false
            }
        }
        return true
    }

    public static func isChatRowStructure(_ evidence: ChatRowStructureEvidence) -> Bool {
        evidence.nonemptyNameLabelCount == 1
            && evidence.profileControlCount == 1
            && evidence.metadataLabelCount == 1
            && evidence.messagePreviewCount == 1
    }

    public static func isVerifiedChatList(
        navigationControls: [NavigationControlEvidence],
        tableCandidateCount: Int
    ) -> Bool {
        guard tableCandidateCount == 1 else { return false }
        let selected = navigationControls.filter(isSelectedChatsNavigation)
        if selected.count == 1 { return true }
        guard selected.isEmpty else { return false }
        return isStatelessChatsNavigationSet(navigationControls)
    }

    public static func preparation(
        expectedTitle: String,
        openRooms: [OpenRoomEvidence],
        matchingRowCount: Int
    ) throws -> RoomPreparation {
        guard matchingRowCount == 1 else {
            let message = matchingRowCount == 0
                ? "The exact destination row is not visible"
                : "The destination label matches multiple UI rows"
            throw SendUIError.preconditionFailed(message)
        }

        let matchingRooms = openRooms.filter { $0.title == expectedTitle }
        let unrelatedRooms = openRooms.filter { $0.title != expectedTitle }
        guard unrelatedRooms.isEmpty else {
            throw SendUIError.preconditionFailed(
                "An unrelated chat room is already open; close it manually before sending"
            )
        }
        guard matchingRooms.count <= 1 else {
            throw SendUIError.preconditionFailed(
                "Multiple open rooms match the destination title"
            )
        }
        if let room = matchingRooms.first {
            guard room.composerCount == 1 else {
                throw SendUIError.preconditionFailed(
                    "The open target room does not expose exactly one verified composer"
                )
            }
            guard room.composerText.isEmpty else {
                throw SendUIError.preconditionFailed(
                    "The open target room contains an unsent draft"
                )
            }
            return .reuse
        }
        return .openExactRow
    }

    public static func verifyFinalRoom(
        expectedTitle: String,
        expectedBody: String,
        evidence: FinalRoomEvidence
    ) throws {
        guard evidence.applicationRunning,
              evidence.exactWindowSet,
              evidence.mainWindowIdentifier == "Main Window",
              evidence.roomTitle == expectedTitle,
              evidence.composerCount == 1,
              evidence.composerIdentityMatches,
              evidence.composerBody == expectedBody,
              evidence.frontmostApplicationUnchanged else {
            throw SendUIError.preconditionFailed(
                "Room or composer identity changed before the send action"
            )
        }
    }
}

/// Safe UI transport. It operates only on an already-running KakaoTalk process
/// with a rendered main window and one already-open exact target room. It never
/// mutates Accessibility focus or posts keyboard/mouse input; the only send
/// action is AXPress on one exact verified Send/전송 control.
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
        guard let initialFrontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw SendUIError.preconditionFailed("The current foreground application could not be verified")
        }
        let appElement = AXUIElementCreateApplication(processID)
        let windows = AXHelpers.windows(appElement)
        let mainWindows = windows.filter {
            AXHelpers.identifier($0) == "Main Window"
        }
        guard mainWindows.count == 1, let mainWindow = mainWindows.first else {
            throw SendUIError.preconditionFailed("KakaoTalk's main window is not rendered; foreground it manually")
        }

        let roomWindows = windows.filter { !CFEqual($0, mainWindow) }
        let table: AXUIElement
        switch AXHelpers.chatListResolution(in: mainWindow) {
        case .verified(let verifiedTable):
            table = verifiedTable
        case .navigationUnverified:
            throw SendUIError.preconditionFailed(
                "KakaoTalk's Chats navigation could not be structurally verified"
            )
        case .tableUnverified:
            throw SendUIError.preconditionFailed(
                "KakaoTalk's current chat-list rows could not be structurally verified"
            )
        }
        let rows = matchingRows(in: table, chat: chat)
        guard rows.count == 1, let verifiedRow = rows.first else {
            let message = rows.isEmpty
                ? "The exact destination row is not visible"
                : "The destination label matches multiple UI rows"
            throw SendUIError.preconditionFailed(message)
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
            let matchingRooms = roomWindows.filter { AXHelpers.title($0) == expectedTitle }
            guard matchingRooms.count == 1, let exactRoom = matchingRooms.first,
                  let currentTable = AXHelpers.chatList(in: mainWindow),
                  CFEqual(currentTable, table) else {
                throw SendUIError.preconditionFailed(
                    "The exact open target room or chat list changed during verification"
                )
            }
            let currentRows = matchingRows(in: currentTable, chat: chat)
            guard currentRows.count == 1,
                  let currentRow = currentRows.first,
                  CFEqual(verifiedRow, currentRow),
                  AXHelpers.windows(appElement).count == 2 else {
                throw SendUIError.preconditionFailed(
                    "The destination identity or window set changed before room reuse"
                )
            }
            room = exactRoom
        case .openExactRow:
            throw SendUIError.preconditionFailed(
                "The exact target room is not already open; open it manually before background sending"
            )
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
        guard let compositionContainer = findCompositionContainer(in: room, composer: composer),
              !CFEqual(compositionContainer, room),
              finalRoomIsVerified(
                  application: application,
                  appElement: appElement,
                  mainWindow: mainWindow,
                  table: table,
                  row: verifiedRow,
                  chat: chat,
                  room: room,
                  expectedTitle: expectedTitle,
                  composer: composer,
                  body: "",
                  compositionContainer: compositionContainer,
                  initialFrontmostProcessID: initialFrontmostProcessID
              ) else {
            throw SendUIError.preconditionFailed(
                "The exact room, row, or composer container changed before composition"
            )
        }

        var actionAttempted = false
        do {
            let preflightControls = sendControlCandidates(in: compositionContainer)
            guard preflightControls.count == 1, let preflightControl = preflightControls.first else {
                throw SendUIError.preconditionFailed(
                    "The exact target room does not expose one unambiguous Send control"
                )
            }
            guard AXHelpers.setValue(composer, body), AXHelpers.value(composer) == body else {
                throw SendUIError.preconditionFailed("KakaoTalk did not accept the exact message bytes")
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == initialFrontmostProcessID else {
                throw SendUIError.preconditionFailed(
                    "The foreground application changed while preparing the background send"
                )
            }

            let controls = exactSendControls(in: compositionContainer)
            if controls.count == 1, let control = controls.first {
                guard CFEqual(control, preflightControl) else {
                    throw SendUIError.preconditionFailed("The exact Send control changed after composition")
                }
                guard finalRoomIsVerified(
                    application: application,
                    appElement: appElement,
                    mainWindow: mainWindow,
                    table: table,
                    row: verifiedRow,
                    chat: chat,
                    room: room,
                    expectedTitle: expectedTitle,
                    composer: composer,
                    body: body,
                    compositionContainer: compositionContainer,
                    initialFrontmostProcessID: initialFrontmostProcessID
                ) else {
                    throw SendUIError.preconditionFailed("Room or composer identity changed before Send")
                }
                let finalControls = exactSendControls(in: compositionContainer)
                guard finalControls.count == 1,
                      finalControls.first.map({ CFEqual($0, control) }) == true,
                      finalRoomIsVerified(
                          application: application,
                          appElement: appElement,
                          mainWindow: mainWindow,
                          table: table,
                          row: verifiedRow,
                          chat: chat,
                          room: room,
                          expectedTitle: expectedTitle,
                          composer: composer,
                          body: body,
                          compositionContainer: compositionContainer,
                          initialFrontmostProcessID: initialFrontmostProcessID
                      ) else {
                    throw SendUIError.preconditionFailed("The exact Send control changed before invocation")
                }
                actionAttempted = true
                guard AXHelpers.perform(control, kAXPressAction as String) else {
                    throw SendUIError.outcomeUnknown("KakaoTalk did not acknowledge the exact Send control")
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == initialFrontmostProcessID else {
                    throw SendUIError.outcomeUnknown(
                        "The foreground application changed after the Send control was invoked"
                    )
                }
            } else if controls.isEmpty {
                throw SendUIError.preconditionFailed(
                    "The exact target room does not expose one enabled Send control"
                )
            } else {
                throw SendUIError.preconditionFailed("Multiple exact Send controls are exposed")
            }
        } catch {
            if !actionAttempted {
                let currentValue = AXHelpers.value(composer)
                let cleared = currentValue?.isEmpty == true
                    || (currentValue == body
                        && AXHelpers.setValue(composer, "")
                        && AXHelpers.value(composer)?.isEmpty == true)
                guard cleared else {
                    throw SendUIError.outcomeUnknown(
                        "No send action was invoked, but the composer changed and safe cleanup could not be proven"
                    )
                }
            }
            throw error
        }
    }

    private func matchingRows(in table: AXUIElement, chat: Chat) -> [AXUIElement] {
        AXHelpers.rows(in: table).filter { row in
            chat.isSelfChat
                ? AXHelpers.isSelfRow(row)
                : AXHelpers.exactName(in: row) == chat.displayName
        }
    }

    private func finalRoomIsVerified(
        application: NSRunningApplication,
        appElement: AXUIElement,
        mainWindow: AXUIElement,
        table: AXUIElement,
        row: AXUIElement,
        chat: Chat,
        room: AXUIElement,
        expectedTitle: String,
        composer: AXUIElement,
        body: String,
        compositionContainer: AXUIElement,
        initialFrontmostProcessID: pid_t
    ) -> Bool {
        let windows = AXHelpers.windows(appElement)
        let composers = composerCandidates(in: room)
        let currentTable = AXHelpers.chatList(in: mainWindow)
        let currentRows = currentTable.map { matchingRows(in: $0, chat: chat) } ?? []
        let currentContainer = findCompositionContainer(in: room, composer: composer)
        let evidence = FinalRoomEvidence(
            applicationRunning: !application.isTerminated,
            exactWindowSet: windows.count == 2
                && windows.contains(where: { CFEqual($0, mainWindow) })
                && windows.contains(where: { CFEqual($0, room) }),
            mainWindowIdentifier: AXHelpers.identifier(mainWindow),
            roomTitle: verifiedRoomWindow(room) ? AXHelpers.title(room) : nil,
            composerCount: composers.count,
            composerIdentityMatches: currentTable.map({ CFEqual($0, table) }) == true
                && currentRows.count == 1
                && currentRows.first.map({ CFEqual($0, row) }) == true
                && composers.first.map({ CFEqual($0, composer) }) == true
                && currentContainer.map({ CFEqual($0, compositionContainer) }) == true,
            composerBody: AXHelpers.value(composer),
            frontmostApplicationUnchanged: NSWorkspace.shared.frontmostApplication?.processIdentifier
                == initialFrontmostProcessID
        )
        do {
            try SendUIValidator.verifyFinalRoom(
                expectedTitle: expectedTitle,
                expectedBody: body,
                evidence: evidence
            )
            return true
        } catch {
            return false
        }
    }

    private func composerCandidates(in room: AXUIElement) -> [AXUIElement] {
        guard verifiedRoomWindow(room) else { return [] }
        return AXHelpers.descendants(room) { element in
            guard AXHelpers.role(element) == kAXTextAreaRole as String,
                  AXHelpers.identifier(element) == "_NS:51",
                  AXHelpers.isSettable(element, kAXValueAttribute as String) else { return false }
            return true
        }
    }

    private func verifiedRoomWindow(_ room: AXUIElement) -> Bool {
        AXHelpers.role(room) == kAXWindowRole as String
            && AXHelpers.subrole(room) == kAXStandardWindowSubrole as String
            && AXHelpers.identifier(room) == "_NS:441"
            && AXHelpers.bool(room, kAXMinimizedAttribute as String) == false
    }

    private func findCompositionContainer(
        in room: AXUIElement,
        composer: AXUIElement
    ) -> AXUIElement? {
        let candidates = AXHelpers.descendants(room) { element in
            AXHelpers.contains(element, composer)
                && self.sendControlCandidates(in: element).count == 1
        }
        return candidates.min {
            AXHelpers.descendants($0, matching: { _ in true }).count
                < AXHelpers.descendants($1, matching: { _ in true }).count
        }
    }

    private func exactSendControls(in room: AXUIElement) -> [AXUIElement] {
        sendControlCandidates(in: room).filter {
            AXHelpers.bool($0, kAXEnabledAttribute as String) == true
        }
    }

    private func sendControlCandidates(in room: AXUIElement) -> [AXUIElement] {
        let accepted = Set(["send", "전송"])
        return AXHelpers.descendants(room) { element in
            guard AXHelpers.role(element) == kAXButtonRole as String,
                  AXHelpers.actions(element).contains(kAXPressAction as String) else { return false }
            let labels = [AXHelpers.title(element), AXHelpers.description(element)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return labels.contains { accepted.contains($0) }
        }
    }

}
