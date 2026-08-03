import ArgumentParser
import Foundation
import KakaoCore

struct DatabaseOptions: ParsableArguments {
    @Option(name: .long, help: "KakaoTalk database path (auto-detected by default)")
    var db: String?

    @Option(name: .long, help: "KakaoTalk database key (auto-derived by default)")
    var key: String?

    var usesOverride: Bool { db != nil || key != nil }
}

func liveClient(_ options: DatabaseOptions) throws -> KakaoClient {
    try KakaoClient.live(databasePath: options.db, databaseKey: options.key)
}

func serviceConnection() -> LocalServiceConnection {
    LocalServiceConnection(socketURL: RuntimePaths().socket)
}

func parseDuration(_ value: String?) -> Date? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let unit = trimmed.last, let number = Double(trimmed.dropLast()) else { return nil }
    let multiplier: Double
    switch unit {
    case "s": multiplier = 1
    case "m": multiplier = 60
    case "h": multiplier = 3_600
    case "d": multiplier = 86_400
    case "w": multiplier = 604_800
    default: return nil
    }
    return Date().addingTimeInterval(-number * multiplier)
}
