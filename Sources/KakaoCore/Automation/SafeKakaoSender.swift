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

public protocol KakaoRoomPreparing: AnyObject, Sendable {
    /// Make the exact database-resolved room reusable without composing or
    /// invoking a Send control. This phase is safe to repeat after failure.
    func prepare(chat: Chat) throws -> RoomWarmupStatus
}

protocol KakaoIdentityRecheckingSendUI: AnyObject {
    func submit(
        chat: Chat,
        body: String,
        finalIdentityCheck: () throws -> Void
    ) throws
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

struct CompositionElementEvidence: Hashable, Sendable {
    let role: String
    let identifier: String
}

struct CompositionWindowEvidence: Sendable {
    let directChildCount: Int
    let identifiedDirectChildren: [CompositionElementEvidence]
    let identifierlessButtonCount: Int
    let fixedLeavesAreEmpty: Bool
    let sliderHasOneAnonymousLeafValueIndicator: Bool
    let emptyIdentifierlessButtonCount: Int
    let nestedIdentifierlessButtonCount: Int
    let nestedButtonHasTwoEmptyGroups: Bool
    let composerScrollCount: Int
    let composerIsOnlyScrollChild: Bool
    let composerIsLeaf: Bool
}

enum CompositionWindowValidator {
    static func isClean(_ evidence: CompositionWindowEvidence) -> Bool {
        let expected = [
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
        guard evidence.directChildCount == 18,
              evidence.identifiedDirectChildren.count == expected.count else { return false }
        for element in expected {
            guard evidence.identifiedDirectChildren.filter({ $0 == element }).count == 1 else {
                return false
            }
        }
        return evidence.identifierlessButtonCount == 9
            && evidence.fixedLeavesAreEmpty
            && evidence.sliderHasOneAnonymousLeafValueIndicator
            && evidence.emptyIdentifierlessButtonCount == 8
            && evidence.nestedIdentifierlessButtonCount == 1
            && evidence.nestedButtonHasTwoEmptyGroups
            && evidence.composerScrollCount == 1
            && evidence.composerIsOnlyScrollChild
            && evidence.composerIsLeaf
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
final class SafeKakaoSender: KakaoSendUI, KakaoRoomPreparing,
    KakaoIdentityRecheckingSendUI, @unchecked Sendable {
    static let bundleIdentifier = "com.kakao.KakaoTalkMac"
    private let roomWarmup = ForegroundRoomWarmup()
    private let preparedIdentityLock = NSLock()
    private var preparedIdentity: PreparedRoomWarmup?

    private struct UnrelatedRoomSnapshot {
        let window: AXUIElement
        let title: String
        let composer: AXUIElement
        let value: String
    }

    init() {}

    func prepare(chat: Chat) throws -> RoomWarmupStatus {
        preparedIdentityLock.withLock { preparedIdentity = nil }
        let prepared = try roomWarmup.prepare(chat: chat)
        preparedIdentityLock.withLock { preparedIdentity = prepared }
        return prepared.status
    }

    func submit(chat: Chat, body: String) throws {
        try submit(chat: chat, body: body, finalIdentityCheck: {})
    }

    func submit(
        chat: Chat,
        body: String,
        finalIdentityCheck: () throws -> Void
    ) throws {
        guard !body.isEmpty else {
            throw SendUIError.preconditionFailed("Message body cannot be empty")
        }
        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).filter { !$0.isTerminated }
        guard runningApplications.count == 1, let application = runningApplications.first else {
            throw SendUIError.preconditionFailed(
                runningApplications.isEmpty
                    ? "KakaoTalk is not running; foreground it manually"
                    : "Multiple KakaoTalk processes are running; the exact process is ambiguous"
            )
        }
        guard let prepared = preparedIdentityLock.withLock({ () -> PreparedRoomWarmup? in
            defer { preparedIdentity = nil }
            return preparedIdentity
        }), chat.id == prepared.chatID,
        chat.displayName == prepared.displayName,
        chat.isSelfChat == prepared.isSelfChat,
        application.processIdentifier == prepared.processID,
        application.bundleIdentifier == prepared.bundleIdentifier,
        application.launchDate == prepared.launchDate else {
            throw SendUIError.preconditionFailed(
                "KakaoTalk's process identity changed after exact-room warm-up"
            )
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
        let rows = AXHelpers.matchingRows(in: table, chat: chat)
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
        guard roomWindows.allSatisfy({ window in
            AXHelpers.isVerifiedRoomWindow(window)
                && AXHelpers.title(window)?.isEmpty == false
                && AXHelpers.composerCandidates(in: window).count == 1
        }) else {
            throw SendUIError.preconditionFailed(
                "A non-room or structurally ambiguous KakaoTalk window is open"
            )
        }
        let roomEvidence = roomWindows.map { window in
            let composers = AXHelpers.composerCandidates(in: window)
            return OpenRoomEvidence(
                title: AXHelpers.title(window) ?? "",
                composerCount: composers.count,
                composerText: composers.first.flatMap(AXHelpers.value) ?? ""
            )
        }
        let unrelatedRooms = roomWindows.filter { AXHelpers.title($0) != expectedTitle }
        let unrelatedSnapshots = unrelatedRooms.compactMap { window -> UnrelatedRoomSnapshot? in
            guard let composer = AXHelpers.composerCandidates(in: window).first,
                  let value = AXHelpers.value(composer) else { return nil }
            guard let title = AXHelpers.title(window) else { return nil }
            return UnrelatedRoomSnapshot(
                window: window,
                title: title,
                composer: composer,
                value: value
            )
        }
        guard unrelatedSnapshots.count == unrelatedRooms.count else {
            throw SendUIError.preconditionFailed(
                "An unrelated room composer could not be stably snapshotted"
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
            let currentRows = AXHelpers.matchingRows(in: currentTable, chat: chat)
            guard currentRows.count == 1,
                  let currentRow = currentRows.first,
                  CFEqual(verifiedRow, currentRow),
                  AXHelpers.sameElementSet(AXHelpers.windows(appElement), windows) else {
                throw SendUIError.preconditionFailed(
                    "The destination identity or window set changed before room reuse"
                )
            }
            room = exactRoom
        case .openExactRow:
            throw SendUIError.preconditionFailed(
                "The exact target room is not prepared; run the exact-ID room warm-up before sending"
            )
        }

        guard AXHelpers.title(room) == expectedTitle else {
            throw SendUIError.preconditionFailed("The opened room title does not exactly match the destination")
        }
        let composers = AXHelpers.composerCandidates(in: room)
        guard composers.count == 1 else {
            throw SendUIError.preconditionFailed("The target room does not expose exactly one verified composer")
        }
        let composer = composers[0]
        guard AXHelpers.value(composer)?.isEmpty == true else {
            throw SendUIError.preconditionFailed("The target room contains an unsent draft")
        }
        guard isCleanCompositionWindow(room, composer: composer) else {
            throw SendUIError.preconditionFailed(
                "The target room contains queued or structurally ambiguous composition state"
            )
        }
        let compositionContainer = room
        let compositionChildren = AXHelpers.children(room)
        guard
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
                  expectedCompositionChildren: compositionChildren,
                  expectedWindows: windows,
                  unrelatedRooms: unrelatedSnapshots,
                  initialFrontmostProcessID: initialFrontmostProcessID
              ) else {
            throw SendUIError.preconditionFailed(
                "The exact room, row, or composer container changed before composition"
            )
        }

        var actionAttempted = false
        var composerMutationAttempted = false
        do {
            let preflightControls = sendControlCandidates(in: compositionContainer)
            guard preflightControls.count == 1, let preflightControl = preflightControls.first else {
                throw SendUIError.preconditionFailed(
                    "The exact target room does not expose one unambiguous Send control"
                )
            }
            composerMutationAttempted = true
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
                    expectedCompositionChildren: compositionChildren,
                    expectedWindows: windows,
                    unrelatedRooms: unrelatedSnapshots,
                    initialFrontmostProcessID: initialFrontmostProcessID
                ) else {
                    throw SendUIError.preconditionFailed("Room or composer identity changed before Send")
                }
                do {
                    try finalIdentityCheck()
                } catch {
                    throw SendUIError.preconditionFailed(
                        "The destination database identity changed before Send"
                    )
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
                          expectedCompositionChildren: compositionChildren,
                          expectedWindows: windows,
                          unrelatedRooms: unrelatedSnapshots,
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
            if !actionAttempted, composerMutationAttempted {
                let currentValue = AXHelpers.value(composer)
                // Cleanup is best-effort only. Another actor can deliver the
                // body between a read and clear, so any failure after our
                // first composer mutation remains durably unknown even when
                // the exact bytes can still be cleared.
                if currentValue == body {
                    _ = AXHelpers.setValue(composer, "")
                }
                throw SendUIError.outcomeUnknown(
                    "No kakaocli Send action was invoked, but composer mutation began and a no-delivery outcome cannot be proven"
                )
            }
            throw error
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
        expectedCompositionChildren: [AXUIElement],
        expectedWindows: [AXUIElement],
        unrelatedRooms: [UnrelatedRoomSnapshot],
        initialFrontmostProcessID: pid_t
    ) -> Bool {
        let windows = AXHelpers.windows(appElement)
        let composers = AXHelpers.composerCandidates(in: room)
        let currentTable = AXHelpers.chatList(in: mainWindow)
        let currentRows = currentTable.map { AXHelpers.matchingRows(in: $0, chat: chat) } ?? []
        let compositionUnchanged = CFEqual(room, compositionContainer)
            && AXHelpers.sameElementSet(AXHelpers.children(room), expectedCompositionChildren)
            && isCleanCompositionWindow(room, composer: composer)
        let evidence = FinalRoomEvidence(
            applicationRunning: isOnlyExactApplication(application),
            exactWindowSet: AXHelpers.sameElementSet(windows, expectedWindows)
                && windows.contains(where: { CFEqual($0, mainWindow) })
                && windows.contains(where: { CFEqual($0, room) })
                && windows.filter { !CFEqual($0, mainWindow) }
                    .allSatisfy(AXHelpers.isVerifiedRoomWindow)
                && unrelatedRoomsAreUnchanged(unrelatedRooms),
            mainWindowIdentifier: AXHelpers.identifier(mainWindow),
            roomTitle: AXHelpers.isVerifiedRoomWindow(room) ? AXHelpers.title(room) : nil,
            composerCount: composers.count,
            composerIdentityMatches: currentTable.map({ CFEqual($0, table) }) == true
                && currentRows.count == 1
                && currentRows.first.map({ CFEqual($0, row) }) == true
                && composers.first.map({ CFEqual($0, composer) }) == true
                && compositionUnchanged,
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

    private func isOnlyExactApplication(_ expected: NSRunningApplication) -> Bool {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).filter { !$0.isTerminated }
        guard running.count == 1, let current = running.first else { return false }
        return current.processIdentifier == expected.processIdentifier
            && current.bundleIdentifier == expected.bundleIdentifier
            && current.launchDate == expected.launchDate
    }

    private func unrelatedRoomsAreUnchanged(_ snapshots: [UnrelatedRoomSnapshot]) -> Bool {
        snapshots.allSatisfy { snapshot in
            let composers = AXHelpers.composerCandidates(in: snapshot.window)
            return AXHelpers.title(snapshot.window) == snapshot.title
                && composers.count == 1
                && composers.first.map { CFEqual($0, snapshot.composer) } == true
                && AXHelpers.value(snapshot.composer) == snapshot.value
        }
    }

    private func isCleanCompositionWindow(
        _ room: AXUIElement,
        composer: AXUIElement
    ) -> Bool {
        guard AXHelpers.isCleanCompositionRoom(room, composer: composer),
              sendControlCandidates(in: room).count == 1 else { return false }
        return true
    }

    private func exactSendControls(in room: AXUIElement) -> [AXUIElement] {
        sendControlCandidates(in: room).filter {
            AXHelpers.bool($0, kAXEnabledAttribute as String) == true
        }
    }

    private func sendControlCandidates(in room: AXUIElement) -> [AXUIElement] {
        let accepted = Set(["send", "전송"])
        return AXHelpers.children(room).filter { element in
            guard AXHelpers.role(element) == kAXButtonRole as String,
                  AXHelpers.identifier(element) == nil,
                  AXHelpers.bool(element, kAXHiddenAttribute as String) != true,
                  AXHelpers.hasContainedFrame(element, in: room),
                  AXHelpers.actions(element).contains(kAXPressAction as String) else { return false }
            let labels = [AXHelpers.title(element), AXHelpers.description(element)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return labels.contains { accepted.contains($0) }
        }
    }

}
