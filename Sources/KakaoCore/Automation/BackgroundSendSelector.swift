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
    let composerContainerIdentityMatches: Bool
    let composerBody: String?
    let foregroundApplicationUnchanged: Bool
}

struct FocusedComposerEvidence: Equatable {
    let roomChildrenMatch: Bool
    let composerContainerMatches: Bool
    let composerCount: Int
    let compositionStructureCertified: Bool
    let composerBody: String?
    let roomIsMain: Bool
    let focusedWindowMatchesRoom: Bool
    let focusedUIElementMatchesComposer: Bool
    let composerIsFocused: Bool
}

enum ComposerIdentityPolicy: Equatable {
    case exactPreMutationComposer
    case structurallyAnchoredAfterMutation
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
    static func isCertifiedTargetedReturnBuild(version: String?, build: String?) -> Bool {
        version == "26.6.1" && build == "1190"
    }

    static func isExactTargetFirstResponder(
        expectedBody: String,
        evidence: FocusedComposerEvidence
    ) -> Bool {
        evidence.roomChildrenMatch
            && evidence.composerContainerMatches
            && evidence.composerCount == 1
            && evidence.compositionStructureCertified
            && evidence.composerBody == expectedBody
            && evidence.roomIsMain
            && evidence.focusedWindowMatchesRoom
            && evidence.focusedUIElementMatchesComposer
            && evidence.composerIsFocused
    }

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
        let currentExpected = [
            CompositionElementEvidence(role: kAXScrollAreaRole as String, identifier: "_NS:29"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:164"),
            CompositionElementEvidence(role: kAXStaticTextRole as String, identifier: "_NS:144"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:10"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:54"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:78"),
            CompositionElementEvidence(role: kAXSliderRole as String, identifier: "_NS:182"),
            CompositionElementEvidence(role: kAXScrollAreaRole as String, identifier: "_NS:47"),
        ]
        let legacyExpected = [
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
        func hasExactIdentifiedSet(_ expected: [CompositionElementEvidence]) -> Bool {
            evidence.identifiedDirectChildren.count == expected.count
                && expected.allSatisfy { item in
                    evidence.identifiedDirectChildren.filter { $0 == item }.count == 1
                }
        }
        let currentLayout = hasExactIdentifiedSet(currentExpected)
            && evidence.identifierlessButtonCount == 8
            && evidence.emptyIdentifierlessButtonCount == 7
            && evidence.anonymousLeafRoles.sorted() == [
                kAXImageRole as String,
                kAXStaticTextRole as String,
            ].sorted()
        let legacyLayout = hasExactIdentifiedSet(legacyExpected)
            && evidence.identifierlessButtonCount == 9
            && evidence.emptyIdentifierlessButtonCount == 8
            && evidence.anonymousLeafRoles.isEmpty
        return evidence.directChildCount == 18
            && (currentLayout || legacyLayout)
            && evidence.anonymousNonLeafCount == 0
            && evidence.fixedLeavesAreEmpty
            && evidence.sliderHasOneAnonymousLeafValueIndicator
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
        let targets = openRooms.filter { $0.title == expectedTitle }
        guard targets.count == 1,
              Set(openRooms.map(\.title)).count == openRooms.count,
              openRooms.allSatisfy({ evidence in
                  !evidence.title.isEmpty
                      && evidence.composerCount == 1
                      && evidence.composerText == ""
              }) else {
            throw AutomationError.preconditionFailed(
                "Every open room must be unique and structurally empty, with exactly one target room"
            )
        }
        return .reuseExactRoom
    }

    static func verifyFinalRoom(
        expectedTitle: String,
        expectedBody: String,
        composerIdentityPolicy: ComposerIdentityPolicy,
        evidence: FinalRoomEvidence
    ) throws {
        guard evidence.applicationRunning,
              evidence.exactWindowSet,
              evidence.mainWindowIdentifier == "Main Window",
              evidence.roomTitle == expectedTitle,
              evidence.composerCount == 1,
              evidence.composerContainerIdentityMatches,
              evidence.composerIdentityMatches
                || composerIdentityPolicy == .structurallyAnchoredAfterMutation,
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
