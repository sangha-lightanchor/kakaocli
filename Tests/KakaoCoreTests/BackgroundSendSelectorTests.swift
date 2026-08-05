import ApplicationServices
import Foundation
import Testing
@testable import KakaoCore

@Suite("Fail-closed send selection")
struct BackgroundSendSelectorTests {
    @Test("pins PID-targeted Return to the self-chat-certified KakaoTalk build")
    func targetedReturnBuild() {
        #expect(BackgroundSendSelector.isCertifiedTargetedReturnBuild(
            version: "26.6.1",
            build: "1190"
        ))
        for candidate in [
            ("26.6.0", "1190"),
            ("26.6.1", "1189"),
            (nil, "1190"),
            ("26.6.1", nil),
        ] as [(String?, String?)] {
            #expect(!BackgroundSendSelector.isCertifiedTargetedReturnBuild(
                version: candidate.0,
                build: candidate.1
            ))
        }
    }

    @Test("requires exact app-level first responder evidence for targeted Return")
    func targetedReturnFirstResponder() {
        func evidence(
            roomChildrenMatch: Bool = true,
            composerContainerMatches: Bool = true,
            composerCount: Int = 1,
            compositionStructureCertified: Bool = true,
            composerBody: String? = "exact bytes",
            roomIsMain: Bool = true,
            focusedWindowMatchesRoom: Bool = true,
            focusedUIElementMatchesComposer: Bool = true,
            composerIsFocused: Bool = true
        ) -> FocusedComposerEvidence {
            FocusedComposerEvidence(
                roomChildrenMatch: roomChildrenMatch,
                composerContainerMatches: composerContainerMatches,
                composerCount: composerCount,
                compositionStructureCertified: compositionStructureCertified,
                composerBody: composerBody,
                roomIsMain: roomIsMain,
                focusedWindowMatchesRoom: focusedWindowMatchesRoom,
                focusedUIElementMatchesComposer: focusedUIElementMatchesComposer,
                composerIsFocused: composerIsFocused
            )
        }

        #expect(BackgroundSendSelector.isExactTargetFirstResponder(
            expectedBody: "exact bytes",
            evidence: evidence()
        ))
        let invalid = [
            evidence(roomChildrenMatch: false),
            evidence(composerContainerMatches: false),
            evidence(composerCount: 0),
            evidence(composerCount: 2),
            evidence(compositionStructureCertified: false),
            evidence(composerBody: "changed"),
            evidence(roomIsMain: false),
            evidence(focusedWindowMatchesRoom: false),
            evidence(focusedUIElementMatchesComposer: false),
            evidence(composerIsFocused: false),
        ]
        for candidate in invalid {
            #expect(!BackgroundSendSelector.isExactTargetFirstResponder(
                expectedBody: "exact bytes",
                evidence: candidate
            ))
        }
    }

    @Test("reuses one exact target alongside only safe empty rooms")
    func openRooms() throws {
        #expect(try BackgroundSendSelector.preparation(
            expectedTitle: "Target",
            openRooms: [OpenRoomEvidence(title: "Target", composerCount: 1, composerText: "")],
            matchingRowCount: 1
        ) == .reuseExactRoom)
        #expect(try BackgroundSendSelector.preparation(
            expectedTitle: "Target",
            openRooms: [
                OpenRoomEvidence(title: "Other", composerCount: 1, composerText: ""),
                OpenRoomEvidence(title: "Target", composerCount: 1, composerText: ""),
            ],
            matchingRowCount: 1
        ) == .reuseExactRoom)

        for rooms in [
            [OpenRoomEvidence(title: "Other", composerCount: 1, composerText: "")],
            [OpenRoomEvidence(title: "Target", composerCount: 0, composerText: nil)],
            [OpenRoomEvidence(title: "Target", composerCount: 1, composerText: nil)],
            [OpenRoomEvidence(title: "Target", composerCount: 1, composerText: "draft")],
            [
                OpenRoomEvidence(title: "Target", composerCount: 1, composerText: ""),
                OpenRoomEvidence(title: "Other", composerCount: 1, composerText: "draft"),
            ],
            [
                OpenRoomEvidence(title: "Target", composerCount: 1, composerText: ""),
                OpenRoomEvidence(title: "Target", composerCount: 1, composerText: ""),
            ],
        ] {
            #expect(throws: AutomationError.self) {
                try BackgroundSendSelector.preparation(
                    expectedTitle: "Target",
                    openRooms: rooms,
                    matchingRowCount: 1
                )
            }
        }
    }

    @Test("closed rooms and ambiguous rows fail before composition")
    func rowIdentity() throws {
        for count in [0, 1, 2, 3] {
            #expect(throws: AutomationError.self) {
                try BackgroundSendSelector.preparation(
                    expectedTitle: "Target",
                    openRooms: [],
                    matchingRowCount: count
                )
            }
        }
    }

    @Test("recognizes only an exact selected Chats navigation control")
    func chatsNavigation() {
        #expect(BackgroundSendSelector.isSelectedChatsNavigation(
            NavigationControlEvidence(
                role: kAXCheckBoxRole as String,
                identifier: "chatrooms",
                title: nil,
                description: nil,
                selected: true,
                enabled: true
            )
        ))
        #expect(BackgroundSendSelector.isSelectedChatsNavigation(
            NavigationControlEvidence(
                role: kAXButtonRole as String,
                identifier: nil,
                title: "Chats",
                description: nil,
                selected: true,
                enabled: true
            )
        ))
        for evidence in [
            NavigationControlEvidence(
                role: kAXCheckBoxRole as String,
                identifier: "contacts",
                title: "Chats",
                description: nil,
                selected: true,
                enabled: true
            ),
            NavigationControlEvidence(
                role: kAXCheckBoxRole as String,
                identifier: "chatrooms",
                title: nil,
                description: nil,
                selected: false,
                enabled: true
            ),
            NavigationControlEvidence(
                role: kAXButtonRole as String,
                identifier: nil,
                title: "Contacts",
                description: nil,
                selected: true,
                enabled: true
            ),
        ] {
            #expect(!BackgroundSendSelector.isSelectedChatsNavigation(evidence))
        }
    }

    @Test("accepts only the complete current stateless navigation set")
    func statelessChatsNavigation() {
        let valid = ["friends", "chatrooms", "more"].map {
            NavigationControlEvidence(
                role: kAXButtonRole as String,
                identifier: $0,
                title: nil,
                description: nil,
                selected: nil,
                enabled: true
            )
        }
        #expect(BackgroundSendSelector.isVerifiedChatList(
            navigationControls: valid,
            tableCandidateCount: 1,
            statelessCandidateHasCurrentChatRowSchema: true
        ))

        let invalidSets = [
            Array(valid.dropLast()),
            valid + [valid[1]],
            valid.map {
                NavigationControlEvidence(
                    role: $0.identifier == "more" ? kAXCheckBoxRole as String : $0.role,
                    identifier: $0.identifier,
                    title: $0.title,
                    description: $0.description,
                    selected: $0.selected,
                    enabled: $0.enabled
                )
            },
            valid.map {
                NavigationControlEvidence(
                    role: $0.role,
                    identifier: $0.identifier,
                    title: $0.title,
                    description: $0.description,
                    selected: $0.identifier == "chatrooms" ? false : $0.selected,
                    enabled: $0.enabled
                )
            },
            valid.map {
                NavigationControlEvidence(
                    role: $0.role,
                    identifier: $0.identifier,
                    title: $0.title,
                    description: $0.description,
                    selected: $0.selected,
                    enabled: $0.identifier == "friends" ? false : $0.enabled
                )
            },
        ]
        for evidence in invalidSets {
            #expect(!BackgroundSendSelector.isVerifiedChatList(
                navigationControls: evidence,
                tableCandidateCount: 1,
                statelessCandidateHasCurrentChatRowSchema: true
            ))
        }
        #expect(!BackgroundSendSelector.isVerifiedChatList(
            navigationControls: valid,
            tableCandidateCount: 2,
            statelessCandidateHasCurrentChatRowSchema: true
        ))
        #expect(!BackgroundSendSelector.isVerifiedChatList(
            navigationControls: valid,
            tableCandidateCount: 1,
            statelessCandidateHasCurrentChatRowSchema: false
        ))
    }

    @Test("accepts only known versioned row-name identifiers")
    func rowNameIdentifiers() {
        for identifier in ["_NS:18", "_NS:40"] {
            #expect(BackgroundSendSelector.isAcceptedChatRowNameIdentifier(identifier))
        }
        for identifier in [nil, "_NS:69", "Display Name", "AXStaticText", ""] {
            #expect(!BackgroundSendSelector.isAcceptedChatRowNameIdentifier(identifier))
        }
    }

    @Test("requires the complete unique current chat-row schema")
    func currentChatRowStructure() {
        let valid = ChatRowStructureEvidence(
            nameLabelCount: 1,
            profileButtonCount: 1,
            metadataLabelCount: 1,
            previewContainerCount: 1
        )
        #expect(BackgroundSendSelector.isCurrentChatRowStructure(valid))
        for keyPath in [
            \ChatRowStructureEvidence.nameLabelCount,
            \ChatRowStructureEvidence.profileButtonCount,
            \ChatRowStructureEvidence.metadataLabelCount,
            \ChatRowStructureEvidence.previewContainerCount,
        ] {
            for invalidCount in [0, 2] {
                let invalid = ChatRowStructureEvidence(
                    nameLabelCount: keyPath == \ChatRowStructureEvidence.nameLabelCount
                        ? invalidCount : 1,
                    profileButtonCount: keyPath == \ChatRowStructureEvidence.profileButtonCount
                        ? invalidCount : 1,
                    metadataLabelCount: keyPath == \ChatRowStructureEvidence.metadataLabelCount
                        ? invalidCount : 1,
                    previewContainerCount: keyPath == \ChatRowStructureEvidence.previewContainerCount
                        ? invalidCount : 1
                )
                #expect(!BackgroundSendSelector.isCurrentChatRowStructure(invalid))
            }
        }
    }

    @Test("accepts only the certified clean current composition window")
    func cleanCompositionWindow() {
        let identified = [
            CompositionElementEvidence(role: kAXScrollAreaRole as String, identifier: "_NS:29"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:164"),
            CompositionElementEvidence(role: kAXStaticTextRole as String, identifier: "_NS:144"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:10"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:54"),
            CompositionElementEvidence(role: kAXButtonRole as String, identifier: "_NS:78"),
            CompositionElementEvidence(role: kAXSliderRole as String, identifier: "_NS:182"),
            CompositionElementEvidence(role: kAXScrollAreaRole as String, identifier: "_NS:47"),
        ]
        func evidence(
            directChildCount: Int = 18,
            composerIsOnlyScrollChild: Bool = true,
            nestedButtonHasTwoEmptyGroups: Bool = true
        ) -> CompositionWindowEvidence {
            CompositionWindowEvidence(
                directChildCount: directChildCount,
                identifiedDirectChildren: identified,
                identifierlessButtonCount: 8,
                anonymousLeafRoles: [kAXImageRole as String, kAXStaticTextRole as String],
                anonymousNonLeafCount: 0,
                fixedLeavesAreEmpty: true,
                sliderHasOneAnonymousLeafValueIndicator: true,
                emptyIdentifierlessButtonCount: 7,
                nestedIdentifierlessButtonCount: 1,
                nestedButtonHasTwoEmptyGroups: nestedButtonHasTwoEmptyGroups,
                composerScrollCount: 1,
                composerIsOnlyScrollChild: composerIsOnlyScrollChild,
                composerIsLeaf: true
            )
        }
        #expect(BackgroundSendSelector.isCleanCompositionWindow(evidence()))
        #expect(!BackgroundSendSelector.isCleanCompositionWindow(evidence(directChildCount: 19)))
        #expect(!BackgroundSendSelector.isCleanCompositionWindow(
            evidence(composerIsOnlyScrollChild: false)
        ))
        #expect(!BackgroundSendSelector.isCleanCompositionWindow(
            evidence(nestedButtonHasTwoEmptyGroups: false)
        ))

        let legacyIdentified = [
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
        let legacy = CompositionWindowEvidence(
            directChildCount: 18,
            identifiedDirectChildren: legacyIdentified,
            identifierlessButtonCount: 9,
            anonymousLeafRoles: [],
            anonymousNonLeafCount: 0,
            fixedLeavesAreEmpty: true,
            sliderHasOneAnonymousLeafValueIndicator: true,
            emptyIdentifierlessButtonCount: 8,
            nestedIdentifierlessButtonCount: 1,
            nestedButtonHasTwoEmptyGroups: true,
            composerScrollCount: 1,
            composerIsOnlyScrollChild: true,
            composerIsLeaf: true
        )
        #expect(BackgroundSendSelector.isCleanCompositionWindow(legacy))
        #expect(!BackgroundSendSelector.isCleanCompositionWindow(
            CompositionWindowEvidence(
                directChildCount: legacy.directChildCount,
                identifiedDirectChildren: legacy.identifiedDirectChildren,
                identifierlessButtonCount: legacy.identifierlessButtonCount,
                anonymousLeafRoles: [kAXStaticTextRole as String],
                anonymousNonLeafCount: legacy.anonymousNonLeafCount,
                fixedLeavesAreEmpty: legacy.fixedLeavesAreEmpty,
                sliderHasOneAnonymousLeafValueIndicator: legacy.sliderHasOneAnonymousLeafValueIndicator,
                emptyIdentifierlessButtonCount: legacy.emptyIdentifierlessButtonCount,
                nestedIdentifierlessButtonCount: legacy.nestedIdentifierlessButtonCount,
                nestedButtonHasTwoEmptyGroups: legacy.nestedButtonHasTwoEmptyGroups,
                composerScrollCount: legacy.composerScrollCount,
                composerIsOnlyScrollChild: legacy.composerIsOnlyScrollChild,
                composerIsLeaf: legacy.composerIsLeaf
            )
        ))
    }

    @Test("final room proof binds the application, windows, title, composer, foreground, and body")
    func finalRoom() throws {
        func evidence(
            applicationRunning: Bool = true,
            exactWindowSet: Bool = true,
            mainWindowIdentifier: String = "Main Window",
            roomTitle: String = "Target",
            composerCount: Int = 1,
            composerIdentityMatches: Bool = true,
            composerContainerIdentityMatches: Bool = true,
            composerBody: String = "exact bytes",
            foregroundApplicationUnchanged: Bool = true
        ) -> FinalRoomEvidence {
            FinalRoomEvidence(
                applicationRunning: applicationRunning,
                exactWindowSet: exactWindowSet,
                mainWindowIdentifier: mainWindowIdentifier,
                roomTitle: roomTitle,
                composerCount: composerCount,
                composerIdentityMatches: composerIdentityMatches,
                composerContainerIdentityMatches: composerContainerIdentityMatches,
                composerBody: composerBody,
                foregroundApplicationUnchanged: foregroundApplicationUnchanged
            )
        }
        let valid = evidence()
        try BackgroundSendSelector.verifyFinalRoom(
            expectedTitle: "Target",
            expectedBody: "exact bytes",
            composerIdentityPolicy: .exactPreMutationComposer,
            evidence: valid
        )
        try BackgroundSendSelector.verifyFinalRoom(
            expectedTitle: "Target",
            expectedBody: "exact bytes",
            composerIdentityPolicy: .structurallyAnchoredAfterMutation,
            evidence: evidence(composerIdentityMatches: false)
        )
        let invalid = [
            evidence(applicationRunning: false),
            evidence(exactWindowSet: false),
            evidence(mainWindowIdentifier: "Other"),
            evidence(roomTitle: "Wrong"),
            evidence(composerCount: 2),
            evidence(composerIdentityMatches: false),
            evidence(composerContainerIdentityMatches: false),
            evidence(composerBody: "changed"),
            evidence(foregroundApplicationUnchanged: false),
        ]
        for evidence in invalid {
            #expect(throws: AutomationError.self) {
                try BackgroundSendSelector.verifyFinalRoom(
                    expectedTitle: "Target",
                    expectedBody: "exact bytes",
                    composerIdentityPolicy: .exactPreMutationComposer,
                    evidence: evidence
                )
            }
        }
        #expect(throws: AutomationError.self) {
            try BackgroundSendSelector.verifyFinalRoom(
                expectedTitle: "Target",
                expectedBody: "exact bytes",
                composerIdentityPolicy: .structurallyAnchoredAfterMutation,
                evidence: evidence(
                    composerIdentityMatches: false,
                    composerContainerIdentityMatches: false
                )
            )
        }
    }

    @Test("selects exact localized controls only and never guesses by position")
    func exactControls() {
        let candidates = [
            BackgroundSendControlCandidate(index: 0, label: "", enabled: true, supportsPress: true),
            BackgroundSendControlCandidate(index: 1, label: "전송", enabled: true, supportsPress: true),
            BackgroundSendControlCandidate(index: 2, label: "Send later", enabled: true, supportsPress: true),
            BackgroundSendControlCandidate(index: 3, label: "Send", enabled: false, supportsPress: true),
        ]
        #expect(BackgroundSendSelector.exactSendControlIndices(from: candidates) == [1])
    }

    @Test("multiple exact controls remain ambiguous")
    func duplicateControls() {
        let candidates = [
            BackgroundSendControlCandidate(index: 0, label: "Send", enabled: true, supportsPress: true),
            BackgroundSendControlCandidate(index: 1, label: "전송", enabled: true, supportsPress: true),
        ]
        #expect(BackgroundSendSelector.exactSendControlIndices(from: candidates) == [0, 1])
    }

    @Test("rejects hidden, nested, identified, wrong-role, and out-of-frame Send controls")
    func structuralSendControls() {
        let invalid = [
            BackgroundSendControlCandidate(
                index: 0, label: "Send", role: kAXCheckBoxRole as String,
                enabled: true, supportsPress: true
            ),
            BackgroundSendControlCandidate(
                index: 1, label: "Send", identifier: "guess", enabled: true,
                supportsPress: true
            ),
            BackgroundSendControlCandidate(
                index: 2, label: "Send", hidden: true, enabled: true,
                supportsPress: true
            ),
            BackgroundSendControlCandidate(
                index: 3, label: "Send", frameContained: false, enabled: true,
                supportsPress: true
            ),
            BackgroundSendControlCandidate(
                index: 4, label: "Send", directChild: false, enabled: true,
                supportsPress: true
            ),
        ]
        #expect(BackgroundSendSelector.exactSendControlIndices(from: invalid).isEmpty)

        let disabled = BackgroundSendControlCandidate(
            index: 5, label: "Send", enabled: false, supportsPress: true
        )
        #expect(BackgroundSendSelector.sendControlCandidateIndices(from: [disabled]) == [5])
        #expect(BackgroundSendSelector.exactSendControlIndices(from: [disabled]).isEmpty)
    }

    @Test("send sources contain no activation, raising, pointer, global input, or Keychain calls")
    func sourceSafetyGuard() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let automator = try String(
            contentsOf: repository.appendingPathComponent("Sources/KakaoCore/Automation/KakaoAutomator.swift"),
            encoding: .utf8
        )
        let command = try String(
            contentsOf: repository.appendingPathComponent("Sources/KakaoCLI/Commands/SendCommand.swift"),
            encoding: .utf8
        )
        let helpers = try String(
            contentsOf: repository.appendingPathComponent("Sources/KakaoCore/Automation/AXHelpers.swift"),
            encoding: .utf8
        )
        let status = try String(
            contentsOf: repository.appendingPathComponent("Sources/KakaoCLI/Commands/StatusCommand.swift"),
            encoding: .utf8
        )
        for prohibited in [
            ".activate(",
            "kAXRaiseAction",
            "CGWarpMouseCursorPosition",
            ".post(tap:",
            "postToPid",
            "CGEvent(keyboardEventSource",
            "CGEvent(mouseEventSource",
            "/usr/bin/security",
        ] {
            #expect(!automator.contains(prohibited))
            #expect(!command.contains(prohibited))
        }
        #expect(!command.contains("foreground"))
        #expect(!command.contains("@Argument"))
        #expect(!command.contains("var key"))
        #expect(!automator.contains("public final class KakaoAutomator"))
        #expect(!automator.contains("AXHelpers.focus(composer"))
        #expect(!automator.contains("sendEvent"))
        #expect(!automator.contains("AXHelpers.performAction"))
        #expect(automator.contains("AXHelpers.postTargetedReturn"))
        #expect(automator.contains("AXHelpers.isFocused"))
        #expect(automator.contains("AXHelpers.setMainWindow"))
        #expect(automator.contains("AXHelpers.setFocused"))
        #expect(!automator.contains("External background submission is disabled"))
        #expect(automator.contains("foregroundProcessID()"))
        let eventCreation = try #require(automator.range(
            of: "guard let returnEvents = AXHelpers.makeTargetedReturnEvents()"
        ))
        let post = try #require(automator.range(
            of: "AXHelpers.postTargetedReturn(returnEvents",
            range: eventCreation.upperBound..<automator.endIndex
        ))
        let finalBoundary = String(automator[eventCreation.upperBound..<post.lowerBound])
        #expect(finalBoundary.contains("exactSendControls(in: room)"))
        #expect(finalBoundary.contains("kAXMainAttribute"))
        #expect(finalBoundary.contains("exactFocusedComposer("))
        #expect(finalBoundary.contains("foregroundProcessID()"))
        let mutationCatch = try #require(automator.range(
            of: "if !actionAttempted, composerMutationAttempted {"
        ))
        let mutationCatchEnd = try #require(automator.range(
            of: "\n            throw error",
            range: mutationCatch.upperBound..<automator.endIndex
        ))
        let postMutationFailure = String(
            automator[mutationCatch.lowerBound..<mutationCatchEnd.lowerBound]
        )
        #expect(postMutationFailure.contains("AutomationError.outcomeUnknown"))
        #expect(!postMutationFailure.contains("AutomationError.preconditionFailed"))
        #expect(helpers.contains("events.keyDown.postToPid(processIdentifier)"))
        #expect(helpers.contains("events.keyUp.postToPid(processIdentifier)"))
        #expect(helpers.contains(
            "return children(appElement).filter { role($0) == kAXWindowRole as String }"
        ))
        #expect(helpers.contains("return chatRowIdentityChrome(row).filter"))
        #expect(helpers.contains("identifier($0) == \"_NS:18\""))
        #expect(!status.contains("CredentialStore()"))
    }
}
