import Foundation

/// Limits enforced consistently by direct callers, the CLI, and the local
/// service. They keep accidental or hostile local input bounded before it
/// reaches SQLCipher, JSON encoding, or the Accessibility send path.
public enum KakaoLimits {
    public static let defaultResultLimit = 50
    public static let maximumChatResults = 500
    public static let maximumMessageResults = 500
    public static let maximumSendBodyBytes = 64 * 1_024
    public static let maximumSearchBytes = 4 * 1_024
    public static let maximumSecretBytes = 4 * 1_024
    public static let maximumServiceRequestBytes = 1 * 1_024 * 1_024
    public static let maximumServicePayloadBytes = 6 * 1_024 * 1_024
    public static let maximumServiceResponseBytes = 8 * 1_024 * 1_024

    public static func validatedResultLimit(_ value: Int, maximum: Int) throws -> Int {
        guard value > 0, value <= maximum else {
            throw KakaoClientError.invalidRequest("limit must be between 1 and \(maximum)")
        }
        return value
    }

    public static func validateSendBody(_ body: String) throws {
        let bytes = body.utf8.count
        guard bytes > 0 else {
            throw KakaoClientError.invalidRequest("Message body cannot be empty")
        }
        guard bytes <= maximumSendBodyBytes else {
            throw KakaoClientError.invalidRequest(
                "Message body exceeds \(maximumSendBodyBytes) UTF-8 bytes"
            )
        }
        guard !body.utf8.contains(0) else {
            throw KakaoClientError.invalidRequest("Message body cannot contain NUL bytes")
        }
    }

    public static func validateSearch(_ search: String?) throws {
        guard let search else { return }
        guard search.utf8.count <= maximumSearchBytes else {
            throw KakaoClientError.invalidRequest(
                "Search exceeds \(maximumSearchBytes) UTF-8 bytes"
            )
        }
    }

    public static func date(
        sinceDuration value: String,
        relativeTo now: Date = Date()
    ) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let unit = trimmed.last,
              let number = Double(trimmed.dropLast()),
              number.isFinite,
              number > 0 else { return nil }
        let multiplier: Double
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        case "w": multiplier = 604_800
        default: return nil
        }
        let interval = number * multiplier
        guard interval.isFinite else { return nil }
        return now.addingTimeInterval(-interval)
    }
}
