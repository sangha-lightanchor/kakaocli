import ApplicationServices
import Foundation
import Testing
@testable import KakaoCore

@Suite("Fail-closed send selection")
struct BackgroundSendSelectorTests {
    @Test("reuses only one exact room with one provably empty composer")
    func openRooms() throws {
        #expect(try BackgroundSendSelector.preparation(
            expectedTitle: "Target",
            openRooms: [OpenRoomEvidence(title: "Target", composerCount: 1, composerText: "")],
            matchingRowCount: 1
        ) == .reuseExactRoom)

        for rooms in [
            [OpenRoomEvidence(title: "Other", composerCount: 1, composerText: "")],
            [OpenRoomEvidence(title: "Target", composerCount: 0, composerText: nil)],
            [OpenRoomEvidence(title: "Target", composerCount: 1, composerText: nil)],
            [OpenRoomEvidence(title: "Target", composerCount: 1, composerText: "draft")],
            [
                OpenRoomEvidence(title: "Target", composerCount: 1, composerText: ""),
                OpenRoomEvidence(title: "Other", composerCount: 1, composerText: ""),
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

    @Test("opens only one exact visible row")
    func rowIdentity() throws {
        #expect(try BackgroundSendSelector.preparation(
            expectedTitle: "Target",
            openRooms: [],
            matchingRowCount: 1
        ) == .openExactRow)
        for count in [0, 2, 3] {
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
                composerBody: composerBody,
                foregroundApplicationUnchanged: foregroundApplicationUnchanged
            )
        }
        let valid = evidence()
        try BackgroundSendSelector.verifyFinalRoom(
            expectedTitle: "Target",
            expectedBody: "exact bytes",
            evidence: valid
        )
        let invalid = [
            evidence(applicationRunning: false),
            evidence(exactWindowSet: false),
            evidence(mainWindowIdentifier: "Other"),
            evidence(roomTitle: "Wrong"),
            evidence(composerCount: 2),
            evidence(composerIdentityMatches: false),
            evidence(composerBody: "changed"),
            evidence(foregroundApplicationUnchanged: false),
        ]
        for evidence in invalid {
            #expect(throws: AutomationError.self) {
                try BackgroundSendSelector.verifyFinalRoom(
                    expectedTitle: "Target",
                    expectedBody: "exact bytes",
                    evidence: evidence
                )
            }
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
        #expect(automator.contains("foregroundProcessID()"))
        #expect(helpers.contains(
            "return children(appElement).filter { role($0) == kAXWindowRole as String }"
        ))
        #expect(!status.contains("CredentialStore()"))
    }
}
