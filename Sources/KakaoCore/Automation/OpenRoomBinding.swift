import AppKit
import ApplicationServices
import Foundation

/// Identity captured while proving that the exact database-resolved room is
/// already rendered. Binding is inspection-only: it never activates KakaoTalk,
/// navigates the chat list, opens a room, or receives message bytes.
struct PreparedOpenRoomBinding {
    let chatID: ChatID
    let displayName: String
    let isSelfChat: Bool
    let processID: pid_t
    let bundleIdentifier: String
    let launchDate: Date
    let foregroundProcessID: pid_t
}

struct OpenRoomBindingEvidence: Sendable {
    let matchingRoomCount: Int
    let sameWindow: Bool
    let exactTitle: Bool
    let composerCount: Int
    let composerIdentityMatches: Bool
    let composerEmpty: Bool
    let cleanComposition: Bool
    let windowSetUnchanged: Bool
    let foregroundUnchanged: Bool
}

enum OpenRoomBindingValidator {
    static func isReady(_ evidence: OpenRoomBindingEvidence) -> Bool {
        evidence.matchingRoomCount == 1
            && evidence.sameWindow
            && evidence.exactTitle
            && evidence.composerCount == 1
            && evidence.composerIdentityMatches
            && evidence.composerEmpty
            && evidence.cleanComposition
            && evidence.windowSetUnchanged
            && evidence.foregroundUnchanged
    }
}

final class OpenRoomBinding: @unchecked Sendable {
    private struct ApplicationIdentity {
        let application: NSRunningApplication
        let processID: pid_t
        let bundleIdentifier: String?
        let launchDate: Date?

        init(_ application: NSRunningApplication) {
            self.application = application
            self.processID = application.processIdentifier
            self.bundleIdentifier = application.bundleIdentifier
            self.launchDate = application.launchDate
        }
    }

    func bind(chat: Chat, timeout: TimeInterval = 5) throws -> PreparedOpenRoomBinding {
        guard let foregroundProcessID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier else {
            throw SendUIError.preconditionFailed(
                "The current foreground application could not be verified"
            )
        }
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: SafeKakaoSender.bundleIdentifier
        ).filter { !$0.isTerminated }
        guard running.count == 1, let kakaoApplication = running.first else {
            throw SendUIError.preconditionFailed(
                running.isEmpty
                    ? "KakaoTalk is not running; open it manually"
                    : "Multiple KakaoTalk processes are running; the exact process is ambiguous"
            )
        }
        let kakao = ApplicationIdentity(kakaoApplication)
        guard kakao.bundleIdentifier == SafeKakaoSender.bundleIdentifier,
              let bundleIdentifier = kakao.bundleIdentifier,
              let launchDate = kakao.launchDate else {
            throw SendUIError.preconditionFailed(
                "KakaoTalk's running-process identity could not be proven"
            )
        }

        let appElement = AXUIElementCreateApplication(kakao.processID)
        let initialWindows = AXHelpers.windows(appElement)
        let initialMainWindows = initialWindows.filter {
            AXHelpers.identifier($0) == "Main Window"
        }
        guard initialMainWindows.count <= 1 else {
            throw SendUIError.preconditionFailed("Multiple KakaoTalk main windows are rendered")
        }
        let initialRoomWindows = roomWindows(
            in: initialWindows,
            mainWindow: initialMainWindows.first
        )
        guard initialRoomWindows.allSatisfy(isStableRoom) else {
            throw SendUIError.preconditionFailed(
                "A non-room or structurally ambiguous KakaoTalk window is open"
            )
        }
        let initialTargets = initialRoomWindows.filter {
            AXHelpers.title($0) == chat.displayName
        }
        guard initialTargets.count <= 1 else {
            throw SendUIError.preconditionFailed(
                "Multiple open rooms match the database-resolved destination"
            )
        }
        guard let initialTarget = initialTargets.first else {
            throw SendUIError.needsUserOpen(
                "Open chat ID \(chat.id.rawValue) in KakaoTalk once, leave its room window open, and retry"
            )
        }
        let initialComposers = AXHelpers.composerCandidates(in: initialTarget)
        guard initialComposers.count == 1, let initialComposer = initialComposers.first else {
            throw SendUIError.preconditionFailed(
                "The open target room does not expose one stable composer"
            )
        }
        guard AXHelpers.value(initialComposer)?.isEmpty == true else {
            throw SendUIError.preconditionFailed("The target room contains an unsent draft")
        }

        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while true {
            guard isCurrent(kakao) else {
                throw SendUIError.preconditionFailed(
                    "KakaoTalk's process identity changed during open-room binding"
                )
            }
            let windows = AXHelpers.windows(appElement)
            let mainWindows = windows.filter { AXHelpers.identifier($0) == "Main Window" }
            let rooms = roomWindows(in: windows, mainWindow: mainWindows.first)
            let targets = rooms.filter { AXHelpers.title($0) == chat.displayName }
            let target = targets.first
            let composers = target.map(AXHelpers.composerCandidates) ?? []
            if let composer = composers.first, AXHelpers.value(composer)?.isEmpty == false {
                throw SendUIError.preconditionFailed("The target room contains an unsent draft")
            }
            let evidence = OpenRoomBindingEvidence(
                matchingRoomCount: targets.count,
                sameWindow: target.map { CFEqual($0, initialTarget) } == true,
                exactTitle: target.map { AXHelpers.title($0) == chat.displayName } == true,
                composerCount: composers.count,
                composerIdentityMatches: composers.first.map {
                    CFEqual($0, initialComposer)
                } == true,
                composerEmpty: composers.first.flatMap(AXHelpers.value)?.isEmpty == true,
                cleanComposition: target.flatMap { room in
                    composers.first.map {
                        AXHelpers.isCleanCompositionRoom(room, composer: $0)
                    }
                } == true,
                windowSetUnchanged: mainWindows.count <= 1
                    && AXHelpers.sameElementSet(windows, initialWindows)
                    && rooms.allSatisfy(isStableRoom),
                foregroundUnchanged: NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == foregroundProcessID
            )
            if OpenRoomBindingValidator.isReady(evidence) {
                return PreparedOpenRoomBinding(
                    chatID: chat.id,
                    displayName: chat.displayName,
                    isSelfChat: chat.isSelfChat,
                    processID: kakao.processID,
                    bundleIdentifier: bundleIdentifier,
                    launchDate: launchDate,
                    foregroundProcessID: foregroundProcessID
                )
            }
            guard targets.count == 1 else {
                throw SendUIError.needsUserOpen(
                    "Chat ID \(chat.id.rawValue) is no longer open in one exact KakaoTalk room"
                )
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw SendUIError.preconditionFailed(
                    "The open target room did not reach a clean bindable state"
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func roomWindows(
        in windows: [AXUIElement],
        mainWindow: AXUIElement?
    ) -> [AXUIElement] {
        windows.filter { window in
            mainWindow.map { !CFEqual(window, $0) } ?? true
        }
    }

    private func isStableRoom(_ window: AXUIElement) -> Bool {
        AXHelpers.isVerifiedRoomWindow(window)
            && AXHelpers.title(window)?.isEmpty == false
            && AXHelpers.composerCandidates(in: window).count == 1
    }

    private func isCurrent(_ expected: ApplicationIdentity) -> Bool {
        guard let current = NSRunningApplication(processIdentifier: expected.processID),
              !current.isTerminated else { return false }
        return current.processIdentifier == expected.processID
            && current.bundleIdentifier == expected.bundleIdentifier
            && current.launchDate == expected.launchDate
    }
}
