import ApplicationServices
import Foundation

struct OpenRoomEvidence: Equatable {
    let title: String
    let composerCount: Int
    let composerText: String?
}

enum RoomPreparation: Equatable {
    case openExactRow
    case reuseExactRoom
}

struct NavigationControlEvidence: Equatable {
    let role: String?
    let identifier: String?
    let title: String?
    let description: String?
    let selected: Bool?
    let enabled: Bool?
}

struct FinalRoomEvidence: Equatable {
    let applicationRunning: Bool
    let exactWindowSet: Bool
    let mainWindowIdentifier: String?
    let roomTitle: String?
    let composerCount: Int
    let composerIdentityMatches: Bool
    let composerFocused: Bool
    let composerBody: String?
}

enum BackgroundSendSelector {
    static func isSelectedChatsNavigation(_ evidence: NavigationControlEvidence) -> Bool {
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

    /// KakaoTalk 26.x exposes its three primary navigation buttons without a
    /// selected-state attribute. Accept that layout only when the complete,
    /// unique, enabled identifier set is present as direct window children.
    static func isStatelessChatsNavigationSet(
        _ evidence: [NavigationControlEvidence]
    ) -> Bool {
        let identifiers = Set(["friends", "chatrooms", "more"])
        let controls = evidence.filter { item in
            item.identifier.map(identifiers.contains) == true
        }
        guard controls.count == identifiers.count,
              Set(controls.compactMap(\.identifier)) == identifiers else {
            return false
        }
        return controls.allSatisfy { item in
            item.role == kAXButtonRole as String
                && item.selected == nil
                && item.enabled == true
        }
    }

    static func isVerifiedChatList(
        navigationControls: [NavigationControlEvidence],
        tableCandidateCount: Int
    ) -> Bool {
        guard tableCandidateCount == 1 else { return false }
        let selected = navigationControls.filter(isSelectedChatsNavigation)
        if selected.count == 1 {
            return true
        }
        guard selected.isEmpty else { return false }
        return isStatelessChatsNavigationSet(navigationControls)
    }

    static func isAcceptedChatRowNameIdentifier(_ identifier: String?) -> Bool {
        Set(["_NS:18", "_NS:40", "Display Name"]).contains(identifier)
    }

    static func preparation(
        expectedTitle: String,
        openRooms: [OpenRoomEvidence],
        matchingRowCount: Int
    ) throws -> RoomPreparation {
        guard matchingRowCount == 1 else {
            throw AutomationError.preconditionFailed(
                matchingRowCount == 0
                    ? "The exact destination row is unavailable"
                    : "The destination label matches multiple rows"
            )
        }

        if openRooms.isEmpty {
            return .openExactRow
        }
        guard openRooms.count == 1,
              openRooms[0].title == expectedTitle,
              openRooms[0].composerCount == 1,
              openRooms[0].composerText == "" else {
            throw AutomationError.preconditionFailed(
                "Only one exact target room with a provably empty composer may be reused"
            )
        }
        return .reuseExactRoom
    }

    static func verifyFinalRoom(
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
              evidence.composerFocused,
              evidence.composerBody == expectedBody else {
            throw AutomationError.preconditionFailed(
                "Room or composer identity changed before the send action"
            )
        }
    }

    static func exactSendControlIndices(from candidates: [BackgroundSendControlCandidate]) -> [Int] {
        let accepted = Set(["send", "전송"])
        return candidates.filter { candidate in
            candidate.enabled && candidate.supportsPress && accepted.contains(
                candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }.map(\.index)
    }
}

struct BackgroundSendControlCandidate {
    let index: Int
    let label: String
    let enabled: Bool
    let supportsPress: Bool
}
