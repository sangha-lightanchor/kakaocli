import CoreGraphics
import Testing
@testable import KakaoCore

@Suite("Background Send control selection")
struct BackgroundSendSelectorTests {
    private let composerFrame = CGRect(x: 100, y: 500, width: 400, height: 80)

    @Test("Localized Send label wins")
    func labeledSendWins() {
        let candidates = [
            BackgroundSendControlCandidate(
                index: 0,
                label: "",
                enabled: true,
                supportsPress: true,
                position: CGPoint(x: 550, y: 590)
            ),
            BackgroundSendControlCandidate(
                index: 1,
                label: "전송",
                enabled: true,
                supportsPress: true,
                position: CGPoint(x: 10, y: 10)
            ),
        ]

        #expect(
            BackgroundSendSelector.sendControlIndex(
                from: candidates,
                inputFrame: composerFrame
            ) == 1
        )
    }

    @Test("Unlabeled lower-right pressable control is selected")
    func layoutFallback() {
        let candidates = [
            BackgroundSendControlCandidate(
                index: 0,
                label: "",
                enabled: true,
                supportsPress: true,
                position: CGPoint(x: 550, y: 200)
            ),
            BackgroundSendControlCandidate(
                index: 1,
                label: "",
                enabled: true,
                supportsPress: true,
                position: CGPoint(x: 520, y: 585)
            ),
            BackgroundSendControlCandidate(
                index: 2,
                label: "",
                enabled: true,
                supportsPress: true,
                position: CGPoint(x: 560, y: 600)
            ),
        ]

        #expect(
            BackgroundSendSelector.sendControlIndex(
                from: candidates,
                inputFrame: composerFrame
            ) == 2
        )
    }

    @Test("Disabled and non-pressable controls are rejected")
    func rejectsUnsafeControls() {
        let candidates = [
            BackgroundSendControlCandidate(
                index: 0,
                label: "Send",
                enabled: false,
                supportsPress: true,
                position: CGPoint(x: 560, y: 600)
            ),
            BackgroundSendControlCandidate(
                index: 1,
                label: "Send",
                enabled: true,
                supportsPress: false,
                position: CGPoint(x: 560, y: 600)
            ),
        ]

        #expect(
            BackgroundSendSelector.sendControlIndex(
                from: candidates,
                inputFrame: composerFrame
            ) == nil
        )
    }
}
