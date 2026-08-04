import ArgumentParser
import Foundation
import KakaoCore

struct DatabaseOptions: ParsableArguments {
    @Option(name: .long, help: "KakaoTalk database path (auto-detected by default)")
    var db: String?

    var usesOverride: Bool { db != nil }
}

func liveClient(_ options: DatabaseOptions) throws -> KakaoClient {
    try KakaoClient.live(databasePath: options.db)
}

func serviceConnection() -> LocalServiceConnection {
    LocalServiceConnection(socketURL: RuntimePaths().socket)
}

func parseDuration(_ value: String?) -> Date? {
    guard let value else { return nil }
    return KakaoLimits.date(sinceDuration: value)
}

func readBoundedStdin(maximumBytes: Int, label: String) throws -> Data {
    var data = Data()
    while data.count <= maximumBytes {
        let remaining = maximumBytes - data.count + 1
        guard let chunk = try FileHandle.standardInput.read(
            upToCount: min(16 * 1_024, remaining)
        ), !chunk.isEmpty else { break }
        data.append(chunk)
    }
    guard data.count <= maximumBytes else {
        throw ValidationError("\(label) exceeds \(maximumBytes) bytes")
    }
    return data
}
