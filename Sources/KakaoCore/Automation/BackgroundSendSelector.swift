import Foundation

struct OpenRoomEvidence: Equatable {
    let title: String
    let composerCount: Int
    let composerText: String
}

enum RoomPreparation: Equatable {
    case reuse
    case openExactRow
}

enum BackgroundSendSelector {
    static func preparation(
        expectedTitle: String,
        openRooms: [OpenRoomEvidence],
        matchingRowCount: Int
    ) throws -> RoomPreparation {
        if !openRooms.isEmpty {
            guard openRooms.count == 1 else {
                throw AutomationError.preconditionFailed("Multiple chat rooms are open")
            }
            let room = openRooms[0]
            guard room.title == expectedTitle else {
                throw AutomationError.preconditionFailed("An unrelated chat room is open")
            }
            guard room.composerCount == 1 else {
                throw AutomationError.preconditionFailed("The target composer is ambiguous")
            }
            guard room.composerText.isEmpty else {
                throw AutomationError.preconditionFailed("The target room contains an unsent draft")
            }
            return .reuse
        }
        guard matchingRowCount == 1 else {
            throw AutomationError.preconditionFailed(
                matchingRowCount == 0
                    ? "The exact destination row is unavailable"
                    : "The destination label matches multiple rows"
            )
        }
        return .openExactRow
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
