import Testing
import Foundation
@testable import KakaoCore

@Suite("Fail-closed send selection")
struct BackgroundSendSelectorTests {
    @Test("reuses only the exact room with one empty composer")
    func exactRoomReuse() throws {
        #expect(try BackgroundSendSelector.preparation(
            expectedTitle: "Target",
            openRooms: [OpenRoomEvidence(title: "Target", composerCount: 1, composerText: "")],
            matchingRowCount: 1
        ) == .reuse)
    }

    @Test("rejects unrelated and multiple open rooms")
    func staleRooms() {
        #expect(throws: AutomationError.self) {
            try BackgroundSendSelector.preparation(
                expectedTitle: "Target",
                openRooms: [OpenRoomEvidence(title: "Other", composerCount: 1, composerText: "")],
                matchingRowCount: 1
            )
        }
        #expect(throws: AutomationError.self) {
            try BackgroundSendSelector.preparation(
                expectedTitle: "Target",
                openRooms: [
                    OpenRoomEvidence(title: "Target", composerCount: 1, composerText: ""),
                    OpenRoomEvidence(title: "Other", composerCount: 1, composerText: ""),
                ],
                matchingRowCount: 1
            )
        }
    }

    @Test("rejects duplicate UI names")
    func duplicateRows() {
        #expect(throws: AutomationError.self) {
            try BackgroundSendSelector.preparation(
                expectedTitle: "Target",
                openRooms: [],
                matchingRowCount: 2
            )
        }
    }

    @Test("rejects nonempty drafts and ambiguous composers")
    func drafts() {
        #expect(throws: AutomationError.self) {
            try BackgroundSendSelector.preparation(
                expectedTitle: "Target",
                openRooms: [OpenRoomEvidence(title: "Target", composerCount: 1, composerText: "draft")],
                matchingRowCount: 1
            )
        }
        #expect(throws: AutomationError.self) {
            try BackgroundSendSelector.preparation(
                expectedTitle: "Target",
                openRooms: [OpenRoomEvidence(title: "Target", composerCount: 2, composerText: "")],
                matchingRowCount: 1
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

    @Test("send sources contain no activation, raising, pointer, or global input calls")
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
        for prohibited in [".activate(", "kAXRaiseAction", "CGWarpMouseCursorPosition", ".post(tap:", "CGEvent(mouseEventSource"] {
            #expect(!automator.contains(prohibited))
        }
        #expect(!command.contains("foreground"))
        #expect(!command.contains("@Argument"))
    }
}
