import ArgumentParser
import Foundation

/// Read a one-shot SQLCipher key without exposing it in argv or shell history.
/// The value is bounded and never persisted by this helper.
func databaseKeyFromStdin(ifRequested requested: Bool) throws -> String? {
    guard requested else { return nil }
    let maximumBytes = 16 * 1_024
    var data = Data()
    while data.count <= maximumBytes {
        let remaining = maximumBytes + 1 - data.count
        guard remaining > 0 else { break }
        let chunk = try FileHandle.standardInput.read(
            upToCount: min(8 * 1_024, remaining)
        ) ?? Data()
        guard !chunk.isEmpty else { break }
        data.append(chunk)
    }
    guard data.count <= maximumBytes else {
        throw ValidationError("stdin database key is too large")
    }
    guard let value = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .newlines), !value.isEmpty else {
        throw ValidationError("stdin database key must be nonempty UTF-8")
    }
    return value
}
