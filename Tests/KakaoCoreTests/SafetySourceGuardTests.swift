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
            "/usr/bin/security",
            "find-generic-password",
            "com.kakaocli.sqlcipher",
        ]
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(!contents.contains(token), "Forbidden token \(token) in \(file.lastPathComponent)")
            }
        }
    }

    @Test("state-key reads remain explicitly noninteractive")
    func noninteractiveStateKey() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let keyStore = root.appendingPathComponent("Sources/KakaoCore/StateKeyStore.swift")
        let contents = try String(contentsOf: keyStore, encoding: .utf8)
        #expect(contents.contains("interactionNotAllowed = true"))
        #expect(!contents.contains("SecItemUpdate"))
    }

    @Test("public send remains synchronously actor-isolated")
    func actorIsolatedSend() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let clientFile = root.appendingPathComponent("Sources/KakaoCore/KakaoClient.swift")
        let contents = try String(contentsOf: clientFile, encoding: .utf8)
        guard let start = contents.range(of: "public func send(_ request: SendRequest)"),
              let end = contents.range(of: "public func events()", range: start.upperBound..<contents.endIndex) else {
            Issue.record("Could not locate KakaoClient.send")
            return
        }
        let implementation = String(contents[start.lowerBound..<end.lowerBound])
        #expect(!implementation.contains("async"))
        #expect(!implementation.contains("Task.detached"))
        #expect(!implementation.contains("DispatchQueue"))
        #expect(!implementation.contains("Continuation"))
    }
}
