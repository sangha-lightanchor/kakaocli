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
            "LocalAuthentication",
            "SecItem",
        ]
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(!contents.contains(token), "Forbidden token \(token) in \(file.lastPathComponent)")
            }
        }
    }

    @Test("state-key storage remains prompt-free and fail-closed")
    func promptFreeStateKey() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let keyStore = root.appendingPathComponent("Sources/KakaoCore/StateKeyStore.swift")
        let contents = try String(contentsOf: keyStore, encoding: .utf8)
        for token in ["lstat(", "fstat(", "geteuid()", "O_NOFOLLOW", "O_EXCL", "fsync(", "0o600"] {
            #expect(contents.contains(token), "Missing state-key protection: \(token)")
        }
        #expect(!contents.contains("Keychain"))
        #expect(!contents.contains("LAContext"))
        #expect(!contents.contains("SecItem"))
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

    @Test("confirmed-receipt recovery remains read-only and UI-free")
    func receiptRecoveryIsUIFree() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let importer = root.appendingPathComponent(
            "Sources/KakaoCore/Migration/ConfirmedReceiptImporter.swift"
        )
        let contents = try String(contentsOf: importer, encoding: .utf8)
        for forbidden in ["SafeKakaoSender", "KakaoSendUI", ".submit(", "AXUIElement", "CGEvent"] {
            #expect(!contents.contains(forbidden), "Receipt recovery contains UI token \(forbidden)")
        }
        #expect(contents.contains("confirmedOutgoing("))
    }
}
