import CoreGraphics
import Foundation

struct BackgroundSendControlCandidate {
    let index: Int
    let label: String
    let enabled: Bool
    let supportsPress: Bool
    let position: CGPoint?
}

enum BackgroundSendSelector {
    /// Select KakaoTalk's Send control without relying on a private AX ID.
    /// Prefer a localized label when KakaoTalk exposes one, then fall back to
    /// an enabled pressable control positioned to the lower-right of the
    /// composer.
    static func sendControlIndex(
        from candidates: [BackgroundSendControlCandidate],
        inputFrame: CGRect
    ) -> Int? {
        let actionable = candidates.filter { $0.enabled && $0.supportsPress }

        if let labeled = actionable.first(where: {
            $0.label.localizedCaseInsensitiveContains("send") || $0.label.contains("전송")
        }) {
            return labeled.index
        }

        return actionable
            .filter {
                guard let position = $0.position else { return false }
                return position.x > inputFrame.midX && position.y >= inputFrame.minY
            }
            .max {
                guard let left = $0.position, let right = $1.position else { return false }
                if left.y == right.y {
                    return left.x < right.x
                }
                return left.y < right.y
            }?
            .index
    }
}
