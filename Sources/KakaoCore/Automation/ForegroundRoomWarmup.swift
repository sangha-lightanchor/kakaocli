import AppKit
import ApplicationServices
import Foundation

/// The only source file allowed to acquire KakaoTalk's foreground and invoke
/// the exact database-resolved row's context-menu "enter chatroom" action. It
/// never receives message bytes and never discovers or invokes a Send control.
struct PreparedRoomWarmup {
    let status: RoomWarmupStatus
    let chatID: ChatID
    let displayName: String
    let isSelfChat: Bool
    let processID: pid_t
    let bundleIdentifier: String
    let launchDate: Date
    let foregroundProcessID: pid_t
}

struct RoomWarmupMenuEvidence: Sendable {
    let matchingItemCount: Int
    let exactForeground: Bool
    let sceneUnchanged: Bool
    let menuStillPresent: Bool
    let itemBelongsToMenu: Bool
}

struct RoomWarmupOpenedRoomEvidence: Sendable {
    let windowDelta: Int
    let newWindowCount: Int
    let verifiedRoomWindow: Bool
    let exactTitle: Bool
    let composerCount: Int
    let composerEmpty: Bool
    let cleanComposition: Bool
}

enum RoomWarmupValidator {
    static func permitsOpenItemPress(_ evidence: RoomWarmupMenuEvidence) -> Bool {
        evidence.matchingItemCount == 1
            && evidence.exactForeground
            && evidence.sceneUnchanged
            && evidence.menuStillPresent
            && evidence.itemBelongsToMenu
    }

    static func isExactOpenedRoom(_ evidence: RoomWarmupOpenedRoomEvidence) -> Bool {
        evidence.windowDelta == 1
            && evidence.newWindowCount == 1
            && evidence.verifiedRoomWindow
            && evidence.exactTitle
            && evidence.composerCount == 1
            && evidence.composerEmpty
            && evidence.cleanComposition
    }
}

final class ForegroundRoomWarmup: @unchecked Sendable {
    private struct ApplicationIdentity {
        let application: NSRunningApplication
        let processID: pid_t
        let bundleIdentifier: String?
        let launchDate: Date?
        let activationPolicy: NSApplication.ActivationPolicy

        init(_ application: NSRunningApplication) {
            self.application = application
            self.processID = application.processIdentifier
            self.bundleIdentifier = application.bundleIdentifier
            self.launchDate = application.launchDate
            self.activationPolicy = application.activationPolicy
        }
    }

    private struct RoomSnapshot {
        let window: AXUIElement
        let title: String
        let composer: AXUIElement
        let composerValue: String
    }

    private struct Scene {
        let windows: [AXUIElement]
        let mainWindow: AXUIElement
        let table: AXUIElement
        let row: AXUIElement
        let rooms: [RoomSnapshot]

        func targetRoom(title: String) -> RoomSnapshot? {
            rooms.first { $0.title == title }
        }
    }

    private enum RestorationResult {
        case restored
        case superseded
        case failed
    }

    func prepare(chat: Chat) throws -> PreparedRoomWarmup {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: SafeKakaoSender.bundleIdentifier
        ).filter { !$0.isTerminated }
        guard running.count == 1, let kakaoApplication = running.first else {
            throw SendUIError.preconditionFailed(
                running.isEmpty
                    ? "KakaoTalk is not running; open it manually once before warm-up"
                    : "Multiple KakaoTalk processes are running; the exact process is ambiguous"
            )
        }
        let kakao = ApplicationIdentity(kakaoApplication)
        guard kakao.bundleIdentifier == SafeKakaoSender.bundleIdentifier,
              kakao.launchDate != nil else {
            throw SendUIError.preconditionFailed(
                "KakaoTalk's running-process identity could not be proven"
            )
        }
        let appElement = AXUIElementCreateApplication(kakao.processID)
        let baseline = try captureScene(appElement: appElement, chat: chat)
        if let room = baseline.targetRoom(title: chat.displayName) {
            guard room.composerValue.isEmpty,
                  AXHelpers.isCleanCompositionRoom(room.window, composer: room.composer) else {
                throw SendUIError.preconditionFailed(
                    "The target room contains a draft or queued/ambiguous composition state"
                )
            }
            guard let foregroundProcessID = NSWorkspace.shared.frontmostApplication?
                .processIdentifier else {
                throw SendUIError.preconditionFailed(
                    "The current foreground application could not be verified"
                )
            }
            return prepared(
                .alreadyOpen,
                chat: chat,
                kakao: kakao,
                foregroundProcessID: foregroundProcessID
            )
        }
        // Temporary activation can redirect a person's physical keystrokes.
        // Do not activate while any existing room holds text that Return could
        // deliver. Already-open target reuse above requires no activation.
        guard baseline.rooms.allSatisfy({ room in
            room.composerValue.isEmpty
                && AXHelpers.isCleanCompositionRoom(room.window, composer: room.composer)
        }) else {
            throw SendUIError.preconditionFailed(
                "A different open KakaoTalk room contains a draft or queued/ambiguous composition state; clear or close it before exact-room warm-up"
            )
        }

        guard let priorApplication = NSWorkspace.shared.frontmostApplication else {
            throw SendUIError.preconditionFailed(
                "The application to restore after room warm-up could not be verified"
            )
        }
        let prior = ApplicationIdentity(priorApplication)
        guard prior.processID == kakao.processID
                || (prior.activationPolicy == .regular
                    && prior.bundleIdentifier != nil
                    && prior.launchDate != nil) else {
            throw SendUIError.preconditionFailed(
                "The foreground application cannot be safely restored after room warm-up"
            )
        }

        if prior.processID == kakao.processID {
            guard isExactFrontmost(kakao), kakao.application.isActive else {
                throw SendUIError.preconditionFailed("KakaoTalk is not stably foregrounded")
            }
            let status = try openExactRoom(
                chat: chat,
                kakao: kakao,
                appElement: appElement,
                baseline: baseline
            )
            return prepared(
                status,
                chat: chat,
                kakao: kakao,
                foregroundProcessID: kakao.processID
            )
        }

        guard isExactFrontmost(prior), isCurrentIdentity(prior) else {
            throw SendUIError.preconditionFailed(
                "The foreground application changed before room warm-up"
            )
        }

        let operation: Result<RoomWarmupStatus, Error>
        if kakao.application.activate(options: []) {
            operation = Result {
                guard waitForFrontmost(kakao, allowing: prior, timeout: 2) else {
                    throw SendUIError.preconditionFailed(
                        "KakaoTalk did not become the verified foreground application"
                    )
                }
                return try openExactRoom(
                    chat: chat,
                    kakao: kakao,
                    appElement: appElement,
                    baseline: baseline,
                    waitForOpenedRoom: false
                )
            }
        } else {
            operation = .failure(SendUIError.preconditionFailed(
                "macOS rejected the temporary KakaoTalk activation request"
            ))
        }

        let restoration = restore(prior: prior, from: kakao)
        switch (operation, restoration) {
        case (.success(let status), .restored):
            if case .opened = status {
                try verifyOpenedRoomAfterRestoration(
                    chat: chat,
                    kakao: kakao,
                    prior: prior,
                    appElement: appElement,
                    baseline: baseline
                )
            }
            return prepared(
                status,
                chat: chat,
                kakao: kakao,
                foregroundProcessID: prior.processID
            )
        case (.success, .superseded):
            throw SendUIError.preconditionFailed(
                "The foreground application changed during warm-up; the room may be open, but no message was composed or sent"
            )
        case (.success, .failed):
            throw SendUIError.preconditionFailed(
                "The exact room opened, but the prior application could not be safely restored; no message was composed or sent"
            )
        case (.failure(let error), .restored), (.failure(let error), .superseded):
            throw error
        case (.failure, .failed):
            throw SendUIError.preconditionFailed(
                "Room warm-up failed and the prior application could not be safely restored; no message was composed or sent"
            )
        }
    }

    private func prepared(
        _ status: RoomWarmupStatus,
        chat: Chat,
        kakao: ApplicationIdentity,
        foregroundProcessID: pid_t
    ) -> PreparedRoomWarmup {
        PreparedRoomWarmup(
            status: status,
            chatID: chat.id,
            displayName: chat.displayName,
            isSelfChat: chat.isSelfChat,
            processID: kakao.processID,
            bundleIdentifier: kakao.bundleIdentifier!,
            launchDate: kakao.launchDate!,
            foregroundProcessID: foregroundProcessID
        )
    }

    private func verifyOpenedRoomAfterRestoration(
        chat: Chat,
        kakao: ApplicationIdentity,
        prior: ApplicationIdentity,
        appElement: AXUIElement,
        baseline: Scene
    ) throws {
        let verification = Result {
            try waitForExactNewRoom(
                chat: chat,
                kakao: kakao,
                appElement: appElement,
                baseline: baseline,
                requireKakaoForeground: false
            )
        }
        let finalRestoration = restore(prior: prior, from: kakao)
        switch (verification, finalRestoration) {
        case (.success, .restored):
            return
        case (.success, .superseded):
            throw SendUIError.preconditionFailed(
                "The foreground application changed while the room finished opening; no message was composed or sent"
            )
        case (.success, .failed):
            throw SendUIError.preconditionFailed(
                "The room opened, but the prior application could not be stably restored; no message was composed or sent"
            )
        case (.failure(let error), .restored), (.failure(let error), .superseded):
            throw error
        case (.failure, .failed):
            throw SendUIError.preconditionFailed(
                "Room verification failed and the prior application could not be stably restored; no message was composed or sent"
            )
        }
    }

    private func openExactRoom(
        chat: Chat,
        kakao: ApplicationIdentity,
        appElement: AXUIElement,
        baseline: Scene,
        waitForOpenedRoom: Bool = true
    ) throws -> RoomWarmupStatus {
        guard isExactForeground(kakao) else {
            throw SendUIError.preconditionFailed("KakaoTalk lost the foreground before room warm-up")
        }
        let foregroundScene = try captureScene(appElement: appElement, chat: chat)
        guard sameScene(foregroundScene, baseline) else {
            throw SendUIError.preconditionFailed(
                "KakaoTalk's destination row or window set changed during activation"
            )
        }
        if let room = foregroundScene.targetRoom(title: chat.displayName) {
            guard room.composerValue.isEmpty,
                  AXHelpers.isCleanCompositionRoom(room.window, composer: room.composer) else {
                throw SendUIError.preconditionFailed(
                    "The target room contains a draft or queued/ambiguous composition state"
                )
            }
            return .alreadyOpen
        }

        let rowCells = AXHelpers.children(baseline.row).filter { cell in
            AXHelpers.role(cell) == kAXCellRole as String
                && AXHelpers.actions(cell).contains(kAXShowMenuAction as String)
        }
        guard rowCells.count == 1, let rowCell = rowCells.first else {
            throw SendUIError.preconditionFailed(
                "The exact destination row does not expose one row-bound context menu"
            )
        }
        let existingMenus = menuElements(in: appElement)
        guard isExactForeground(kakao),
              sameScene(try captureScene(appElement: appElement, chat: chat), baseline),
              AXHelpers.perform(rowCell, kAXShowMenuAction as String) else {
            throw SendUIError.preconditionFailed(
                "KakaoTalk did not acknowledge the exact row context menu"
            )
        }
        let menu = try waitForNewMenu(
            appElement: appElement,
            existingMenus: existingMenus
        )
        defer {
            if AXHelpers.actions(menu).contains(kAXCancelAction as String) {
                _ = AXHelpers.perform(menu, kAXCancelAction as String)
            }
        }
        let acceptedTitles = try openRoomMenuTitles(for: kakao.application)
        let openItems = AXHelpers.descendants(menu) { item in
            guard AXHelpers.role(item) == kAXMenuItemRole as String,
                  AXHelpers.bool(item, kAXEnabledAttribute as String) == true,
                  AXHelpers.actions(item).contains(kAXPressAction as String),
                  let title = AXHelpers.title(item) else { return false }
            return acceptedTitles.contains(title)
        }
        guard openItems.count == 1, let openItem = openItems.first else {
            throw SendUIError.preconditionFailed(
                "The exact row context menu did not expose one verified enter-chatroom action"
            )
        }
        let menuEvidence = RoomWarmupMenuEvidence(
            matchingItemCount: openItems.count,
            exactForeground: isExactForeground(kakao),
            sceneUnchanged: sameScene(
                try captureScene(appElement: appElement, chat: chat), baseline
            ),
            menuStillPresent: menuElements(in: appElement).contains(where: { CFEqual($0, menu) }),
            itemBelongsToMenu: AXHelpers.contains(menu, openItem)
        )
        guard RoomWarmupValidator.permitsOpenItemPress(menuEvidence),
              AXHelpers.perform(openItem, kAXPressAction as String) else {
            throw SendUIError.preconditionFailed(
                "The exact row context menu did not expose one verified enter-chatroom action"
            )
        }
        if waitForOpenedRoom {
            try waitForExactNewRoom(
                chat: chat,
                kakao: kakao,
                appElement: appElement,
                baseline: baseline,
                requireKakaoForeground: true
            )
        }
        return .opened
    }

    private func waitForNewMenu(
        appElement: AXUIElement,
        existingMenus: [AXUIElement]
    ) throws -> AXUIElement {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            let newMenus = menuElements(in: appElement).filter { candidate in
                !existingMenus.contains { CFEqual(candidate, $0) }
            }
            if newMenus.count == 1, let menu = newMenus.first { return menu }
            if newMenus.count > 1 {
                throw SendUIError.preconditionFailed(
                    "Multiple context menus appeared for one destination row"
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw SendUIError.preconditionFailed(
            "The exact destination row context menu did not appear"
        )
    }

    private func menuElements(in appElement: AXUIElement) -> [AXUIElement] {
        AXHelpers.descendants(appElement, matching: { element in
            AXHelpers.role(element) == kAXMenuRole as String
        }, maximumDepth: 16)
    }

    private func openRoomMenuTitles(
        for application: NSRunningApplication
    ) throws -> Set<String> {
        let key = "ChatTab_Rightclick_GoChatRoom"
        guard let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL),
              bundle.bundleIdentifier == SafeKakaoSender.bundleIdentifier else {
            throw SendUIError.preconditionFailed(
                "KakaoTalk's localized enter-chatroom action could not be verified"
            )
        }
        let title = bundle.localizedString(
            forKey: key,
            value: nil,
            table: "Localizable"
        )
        guard title != key, !title.isEmpty else {
            throw SendUIError.preconditionFailed(
                "KakaoTalk's localized enter-chatroom action is unavailable"
            )
        }
        return [title]
    }

    private func waitForExactNewRoom(
        chat: Chat,
        kakao: ApplicationIdentity,
        appElement: AXUIElement,
        baseline: Scene,
        requireKakaoForeground: Bool
    ) throws {
        // Keep the foreground interval after the menu action tightly bounded.
        // A slower room may finish opening after restoration and can be safely
        // recognized as already open on a later no-message warm-up.
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard requireKakaoForeground ? isExactForeground(kakao) : isCurrentIdentity(kakao) else {
                throw SendUIError.preconditionFailed(
                    "KakaoTalk's verified process changed while opening the room"
                )
            }
            let windows = AXHelpers.windows(appElement)
            guard baseline.windows.allSatisfy({ original in
                windows.filter { CFEqual(original, $0) }.count == 1
            }), windows.count <= baseline.windows.count + 1 else {
                throw SendUIError.preconditionFailed(
                    "An existing window changed or multiple windows opened during warm-up"
                )
            }
            if windows.count == baseline.windows.count {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            let newWindows = windows.filter { candidate in
                !baseline.windows.contains { CFEqual(candidate, $0) }
            }
            guard newWindows.count == 1, let newRoom = newWindows.first else {
                throw SendUIError.preconditionFailed(
                    "The newly opened window is not the exact verified destination room"
                )
            }
            let composers = AXHelpers.composerCandidates(in: newRoom)
            if composers.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            let composer = composers.first
            let openedRoomEvidence = RoomWarmupOpenedRoomEvidence(
                windowDelta: windows.count - baseline.windows.count,
                newWindowCount: newWindows.count,
                verifiedRoomWindow: AXHelpers.isVerifiedRoomWindow(newRoom),
                exactTitle: AXHelpers.title(newRoom) == chat.displayName,
                composerCount: composers.count,
                composerEmpty: composer.flatMap(AXHelpers.value)?.isEmpty == true,
                cleanComposition: composer.map {
                    AXHelpers.isCleanCompositionRoom(newRoom, composer: $0)
                } == true
            )
            guard RoomWarmupValidator.isExactOpenedRoom(openedRoomEvidence) else {
                throw SendUIError.preconditionFailed(
                    "The newly opened target room does not expose one clean empty composer"
                )
            }
            let openedScene = try captureScene(appElement: appElement, chat: chat)
            guard openedScene.targetRoom(title: chat.displayName) != nil,
                  preservesBaseline(openedScene, baseline: baseline) else {
                throw SendUIError.preconditionFailed(
                    "The destination identity changed while the room was opening"
                )
            }
            return
        }
        throw SendUIError.preconditionFailed("The verified destination room did not open")
    }

    private func captureScene(appElement: AXUIElement, chat: Chat) throws -> Scene {
        let windows = AXHelpers.windows(appElement)
        let mainWindows = windows.filter { AXHelpers.identifier($0) == "Main Window" }
        guard mainWindows.count == 1, let mainWindow = mainWindows.first else {
            throw SendUIError.preconditionFailed(
                "KakaoTalk's main window is not rendered; open it manually once before warm-up"
            )
        }

        let table: AXUIElement
        switch AXHelpers.chatListResolution(in: mainWindow) {
        case .verified(let verifiedTable): table = verifiedTable
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
        guard rows.count == 1, let row = rows.first else {
            throw SendUIError.preconditionFailed(
                rows.isEmpty
                    ? "The exact destination row is not visible"
                    : "The destination label matches multiple UI rows"
            )
        }

        var rooms: [RoomSnapshot] = []
        for window in windows where !CFEqual(window, mainWindow) {
            guard AXHelpers.isVerifiedRoomWindow(window),
                  let title = AXHelpers.title(window),
                  !title.isEmpty else {
                throw SendUIError.preconditionFailed(
                    "A non-room KakaoTalk window is open; close it before room warm-up"
                )
            }
            let composers = AXHelpers.composerCandidates(in: window)
            guard composers.count == 1, let value = AXHelpers.value(composers[0]) else {
                throw SendUIError.preconditionFailed(
                    "An open KakaoTalk room does not expose one stable composer"
                )
            }
            rooms.append(RoomSnapshot(
                window: window,
                title: title,
                composer: composers[0],
                composerValue: value
            ))
        }
        let targetRooms = rooms.filter { $0.title == chat.displayName }
        guard targetRooms.count <= 1 else {
            throw SendUIError.preconditionFailed(
                "Multiple open rooms match the destination title"
            )
        }
        if let target = targetRooms.first, !target.composerValue.isEmpty {
            throw SendUIError.preconditionFailed("The target room contains an unsent draft")
        }
        return Scene(
            windows: windows,
            mainWindow: mainWindow,
            table: table,
            row: row,
            rooms: rooms
        )
    }

    private func sameScene(_ lhs: Scene, _ rhs: Scene) -> Bool {
        AXHelpers.sameElementSet(lhs.windows, rhs.windows)
            && CFEqual(lhs.mainWindow, rhs.mainWindow)
            && CFEqual(lhs.table, rhs.table)
            && CFEqual(lhs.row, rhs.row)
            && preservesRooms(lhs.rooms, baseline: rhs.rooms)
            && preservesRooms(rhs.rooms, baseline: lhs.rooms)
    }

    private func preservesBaseline(_ scene: Scene, baseline: Scene) -> Bool {
        CFEqual(scene.mainWindow, baseline.mainWindow)
            && CFEqual(scene.table, baseline.table)
            && CFEqual(scene.row, baseline.row)
            && preservesRooms(scene.rooms, baseline: baseline.rooms)
    }

    private func preservesRooms(_ rooms: [RoomSnapshot], baseline: [RoomSnapshot]) -> Bool {
        baseline.allSatisfy { original in
            let matches = rooms.filter { CFEqual($0.window, original.window) }
            guard matches.count == 1, let current = matches.first else { return false }
            return current.title == original.title
                && CFEqual(current.composer, original.composer)
                && current.composerValue == original.composerValue
        }
    }

    private func isExactForeground(_ identity: ApplicationIdentity) -> Bool {
        identity.application.isActive
            && isExactFrontmost(identity)
            && isCurrentIdentity(identity)
    }

    private func isExactFrontmost(_ identity: ApplicationIdentity) -> Bool {
        guard let current = NSWorkspace.shared.frontmostApplication else { return false }
        return matches(current, identity)
    }

    private func isCurrentIdentity(_ identity: ApplicationIdentity) -> Bool {
        guard let current = NSRunningApplication(processIdentifier: identity.processID) else {
            return false
        }
        return matches(current, identity) && !current.isTerminated
    }

    private func matches(
        _ application: NSRunningApplication,
        _ identity: ApplicationIdentity
    ) -> Bool {
        application.processIdentifier == identity.processID
            && application.bundleIdentifier == identity.bundleIdentifier
            && application.launchDate == identity.launchDate
            && application.activationPolicy == identity.activationPolicy
    }

    private func waitForFrontmost(
        _ target: ApplicationIdentity,
        allowing source: ApplicationIdentity,
        timeout: TimeInterval,
        stableSampleCount: Int = 2
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stableSamples = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard isCurrentIdentity(target), isCurrentIdentity(source),
                  let current = NSWorkspace.shared.frontmostApplication else { return false }
            if matches(current, target), target.application.isActive {
                stableSamples += 1
                if stableSamples >= stableSampleCount { return true }
            } else if matches(current, source) {
                stableSamples = 0
            } else {
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func restore(
        prior: ApplicationIdentity,
        from kakao: ApplicationIdentity
    ) -> RestorationResult {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var stableSamples = 0
        var activationAttempts = 0
        var nextActivationAttempt = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard isCurrentIdentity(prior),
                  let current = NSWorkspace.shared.frontmostApplication else { return .failed }
            if matches(current, prior) {
                stableSamples += 1
                if stableSamples >= 10 { return .restored }
            } else if matches(current, kakao) {
                guard isCurrentIdentity(kakao) else { return .failed }
                stableSamples = 0
                let now = ProcessInfo.processInfo.systemUptime
                if now >= nextActivationAttempt {
                    guard activationAttempts < 3 else { return .failed }
                    activationAttempts += 1
                    nextActivationAttempt = now + 0.5
                    guard prior.application.activate(options: []) else {
                        return .failed
                    }
                }
            } else {
                return .superseded
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return .failed
    }
}
