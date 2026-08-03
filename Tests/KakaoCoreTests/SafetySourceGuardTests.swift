import Foundation
import Testing

@Suite("Safety source guard")
struct SafetySourceGuardTests {
    @Test("active source has no activation, raising, cursor, or global event calls")
    func forbiddenCalls() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        let forbidden = [
            ".activate(",
            "kAXRaiseAction",
            "CGWarpMouseCursorPosition",
            ".post(tap:",
            "mouseEventSource:",
            "--foreground",
        ]
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(!contents.contains(token), "Forbidden token \(token) in \(file.lastPathComponent)")
            }
        }
    }
}
