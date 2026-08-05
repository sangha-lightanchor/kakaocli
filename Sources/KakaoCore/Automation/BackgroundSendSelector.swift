import ApplicationServices
import Foundation

struct OpenRoomEvidence: Equatable {
    let title: String
    let composerCount: Int
    let composerText: String?
}

enum RoomPreparation: Equatable {
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

struct ChatRowStructureEvidence: Equatable {
    let nameLabelCount: Int
    let profileButtonCount: Int
    let metadataLabelCount: Int
    let previewContainerCount: Int
}

struct FinalRoomEvidence: Equatable {
    let applicationRunning: Bool
    let exactWindowSet: Bool
    let mainWindowIdentifier: String?
    let roomTitle: String?
    let composerCount: Int
    let composerIdentityMatches: Bool
    let composerBody: String?
    let foregroundApplicationUnchanged: Bool
}

struct CompositionElementEvidence: Hashable {
    let role: String
    let identifier: String
}

struct CompositionWindowEvidence {
    let directChildCount: Int
    let identifiedDirectChildren: [CompositionElementEvidence]
    let identifierlessButtonCount: Int
    let anonymousLeafRoles: [String]
    let anonymousNonLeafCount: Int
    let fixedLeavesAreEmpty: Bool
    let sliderHasOneAnonymousLeafValueIndicator: Bool
    let emptyIdentifierlessButtonCount: Int
    let nestedIdentifierlessButtonCount: Int
    let nestedButtonHasTwoEmptyGroups: Bool
    let composerScrollCount: Int
    let composerIsOnlyScrollChild: Bool
    let composerIsLeaf: Bool
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
        tableCandidateCount: Int,
        statelessCandidateHasCurrentChatRowSchema: Bool
    ) -> Bool {
        guard tableCandidateCount == 1 else { return false }
        let selected = navigationControls.filter(isSelectedChatsNavigation)
        if selected.count == 1 {
            return true
        }
        guard selected.isEmpty else { return false }
        return statelessCandidateHasCurrentChatRowSchema
            && isStatelessChatsNavigationSet(navigationControls)
    }

    static func isAcceptedChatRowNameIdentifier(_ identifier: String?) -> Bool {
        Set(["_NS:18", "_NS:40"]).contains(identifier)
    }

    static func isCurrentChatRowStructure(_ evidence: ChatRowStructureEvidence) -> Bool {
        evidence.nameLabelCount == 1
            && evidence.profileButtonCount == 1
            && evidence.metadataLabelCount == 1
            && evidence.previewContainerCount == 1
    }

    static func isCleanCompositionWindow(_ evidence: CompositionWindowEvidence) -> Bool {
        let expected = [
            CompositionElementEvidence(role: kAXScrollAreaRole as String, identifier: "_NS:29"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:164"),
            CompositionElementEvidence(role: kAXStaticTextRole as String, identifier: "_NS:144"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:10"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:54"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:78"),
            CompositionElementEvidence(role: kAXSliderRole as String, identifier: "_NS:182"),
            CompositionElementEvidence(role: kAXScrollAreaRole as String, identifier: "_NS:47"),
        ]
        guard evidence.directChildCount == 18,
              evidence.identifiedDirectChildren.count == expected.count else { return false }
        for item in expected where evidence.identifiedDirectChildren.filter({ $0 == item }).count != 1 {
            return false
        }
        return evidence.identifierlessButtonCount == 8
            && evidence.anonymousLeafRoles.sorted() == [
                kAXImageRole as String,
                kAXStaticTextRole as String,
            ].sorted()
            && evidence.anonymousNonLeafCount == 0
            && evidence.fixedLeavesAreEmpty
            && evidence.sliderHasOneAnonymousLeafValueIndicator
            && evidence.emptyIdentifierlessButtonCount == 7
            && evidence.nestedIdentifierlessButtonCount == 1
            && evidence.nestedButtonHasTwoEmptyGroups
            && evidence.composerScrollCount == 1
            && evidence.composerIsOnlyScrollChild
            && evidence.composerIsLeaf
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

        guard !openRooms.isEmpty else {
            throw AutomationError.preconditionFailed(
                "Open the exact target room manually once, leave it open, then switch back to another app"
            )
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
              evidence.composerBody == expectedBody,
              evidence.foregroundApplicationUnchanged else {
            throw AutomationError.preconditionFailed(
                "Room or composer identity changed before the send action"
            )
        }
    }

    static func exactSendControlIndices(from candidates: [BackgroundSendControlCandidate]) -> [Int] {
        candidates.filter { $0.enabled && isSendControlCandidate($0) }.map(\.index)
    }

    static func sendControlCandidateIndices(from candidates: [BackgroundSendControlCandidate]) -> [Int] {
        candidates.filter(isSendControlCandidate).map(\.index)
    }

    private static func isSendControlCandidate(
        _ candidate: BackgroundSendControlCandidate
    ) -> Bool {
        let accepted = Set(["send", "전송"])
        return candidate.directChild
            && candidate.role == kAXButtonRole as String
            && candidate.identifier == nil
            && candidate.hidden != true
            && candidate.frameContained
            && candidate.supportsPress
            && accepted.contains(
                candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
    }
}

struct BackgroundSendControlCandidate {
    let index: Int
    let label: String
    let role: String?
    let identifier: String?
    let hidden: Bool?
    let frameContained: Bool
    let directChild: Bool
    let enabled: Bool
    let supportsPress: Bool

    init(
        index: Int,
        label: String,
        role: String? = kAXButtonRole as String,
        identifier: String? = nil,
        hidden: Bool? = nil,
        frameContained: Bool = true,
        directChild: Bool = true,
        enabled: Bool,
        supportsPress: Bool
    ) {
        self.index = index
        self.label = label
        self.role = role
        self.identifier = identifier
        self.hidden = hidden
        self.frameContained = frameContained
        self.directChild = directChild
        self.enabled = enabled
        self.supportsPress = supportsPress
    }
}
