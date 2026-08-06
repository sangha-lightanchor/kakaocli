import Foundation
import Testing

@Suite("Safety source guard")
struct SafetySourceGuardTests {
    @Test("room binding cannot activate or navigate KakaoTalk")
    func forbiddenCalls() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        let forbidden = [
            ".activate(",
            "activateIgnoringOtherApps",
            "activateAllWindows",
            "kAXRaiseAction",
            "kAXMainAttribute",
            "kAXFocusedWindowAttribute",
            "kAXFocusedAttribute",
            "kAXSelectedRowsAttribute",
            "kAXShowMenuAction",
            "kAXCancelAction",
            "makeKeyAndOrderFront",
            "orderFront",
            "orderFrontRegardless",
            "orderWindow",
            "orderBack",
            "orderOut",
            "openApplication",
            "launchApplication",
            "NSWorkspace.shared.open",
            "/usr/bin/open",
            "NSAppleScript",
            "osascript",
            "SetFrontProcess",
            "TransformProcessType",
            "AXRaise",
            "CGWarpMouseCursorPosition",
            "CGDisplayMoveCursorToPoint",
            "CGAssociateMouseAndMouseCursorPosition",
            "CGEventTapPostEvent",
            "CGEventPost(",
            "CGEventPostToPid(",
            "CGEventPostToPSN(",
            "CGPostKeyboardEvent(",
            "CGPostMouseEvent(",
            "AXUIElementPostKeyboardEvent(",
            "CGEvent(",
            "postToPid(",
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

        let binding = sourceRoot.appendingPathComponent(
            "KakaoCore/Automation/OpenRoomBinding.swift"
        )
        let contents = try String(contentsOf: binding, encoding: .utf8)
        for token in [
            "AXHelpers.setValue", "AXHelpers.perform", "SendRequest",
            "sendControlCandidates", "body: String"
        ] {
            #expect(!contents.contains(token), "Open-room binding contains delivery token \(token)")
        }
        #expect(contents.contains("SendUIError.needsUserOpen("))
        #expect(contents.contains("foregroundUnchanged:"))
        #expect(contents.contains("AXHelpers.sameElementSet(windows, initialWindows)"))
    }

    @Test("background sender is control-only")
    func backgroundSenderIsControlOnly() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sender = root.appendingPathComponent("Sources/KakaoCore/Automation/SafeKakaoSender.swift")
        let helpers = root.appendingPathComponent("Sources/KakaoCore/Automation/AXHelpers.swift")
        let contents = try String(contentsOf: sender, encoding: .utf8)
        let helperContents = try String(contentsOf: helpers, encoding: .utf8)
        #expect(contents.contains("sendControlCandidates(in: room)"))
        #expect(contents.contains("return AXHelpers.children(room).filter"))
        #expect(contents.contains("AXHelpers.perform(control, kAXPressAction"))
        #expect(contents.contains("let controls = waitForExactSendControls("))
        #expect(contents.contains("timeout: 2"))
        #expect(contents.contains("private let roomBinding = OpenRoomBinding()"))
        #expect(!contents.contains("ForegroundRoomWarmup"))
        #expect(!contents.contains("RowIdentitySnapshot"))
        #expect(contents.contains("AXHelpers.isCleanCompositionRoom(room, composer: composer)"))
        #expect(contents.contains("guard evidence.directChildCount == 18"))
        for identifier in [
            "_NS:29", "_NS:164", "_NS:144", "_NS:10", "_NS:54",
            "_NS:78", "_NS:182", "_NS:47",
        ] {
            #expect(contents.contains(identifier), "Missing clean-composer identifier \(identifier)")
        }
        #expect(contents.contains("evidence.identifierlessButtonCount == 8"))
        #expect(contents.contains("evidence.emptyIdentifierlessButtonCount == 7"))
        #expect(contents.contains("evidence.anonymousNonLeafCount == 0"))
        #expect(contents.contains("evidence.nestedIdentifierlessButtonCount == 1"))
        #expect(contents.contains("evidence.composerIsLeaf"))
        #expect(helperContents.contains("nestedButtonIsClean"))
        #expect(helperContents.contains("composerChild.map({ CFEqual($0, composer) }) == true"))
        #expect(contents.contains("AXHelpers.identifier(element) == nil"))
        #expect(contents.contains("kAXHiddenAttribute as String) != true"))
        #expect(contents.contains("AXHelpers.hasContainedFrame(element, in: room)"))
        #expect(contents.contains("if !actionAttempted, composerMutationAttempted"))
        #expect(contents.contains("if currentValue == body"))
        #expect(contents.contains("initialFrontmostProcessID == prepared.foregroundProcessID"))
        #expect(contents.contains("UnrelatedRoomIdentityValidator.isStable("))
        #expect(!contents.contains("AXHelpers.value(snapshot.composer)"))
        #expect(!contents.contains("currentValue?.isEmpty == true"))
        #expect(!contents.contains("public final class SafeKakaoSender"))
        #expect(!contents.contains("public func submit(chat: Chat, body: String)"))
        for forbidden in [".activate(", "kAXFocusedAttribute", "kAXSelectedRowsAttribute", "CGEvent(", "postToPid(", "kAXShowMenuAction"] {
            #expect(!contents.contains(forbidden), "Background sender contains \(forbidden)")
        }
    }

    @Test("Accessibility mutations remain closed over exact call sites")
    func accessibilityMutationCallSites() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources")
        let helpers = sourceRoot.appendingPathComponent("KakaoCore/Automation/AXHelpers.swift")
        let sender = sourceRoot.appendingPathComponent("KakaoCore/Automation/SafeKakaoSender.swift")
        let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        let helperContents = try String(contentsOf: helpers, encoding: .utf8)
        #expect(helperContents.components(separatedBy: "AXUIElementPerformAction(").count - 1 == 1)
        #expect(helperContents.components(separatedBy: "AXUIElementSetAttributeValue(").count - 1 == 1)
        for file in files where file.standardizedFileURL != helpers.standardizedFileURL {
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(!contents.contains("AXUIElementPerformAction("))
            #expect(!contents.contains("AXUIElementSetAttributeValue("))
        }

        let senderContents = try String(contentsOf: sender, encoding: .utf8)
        #expect(senderContents.components(separatedBy: "AXHelpers.perform(").count - 1 == 1)
        #expect(senderContents.components(separatedBy: "AXHelpers.setValue(").count - 1 == 2)
        for file in files where file.standardizedFileURL != sender.standardizedFileURL {
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(!contents.contains("AXHelpers.perform("))
            #expect(!contents.contains("AXHelpers.setValue("))
        }
        #expect(senderContents.contains("AXHelpers.setValue(composer, body)"))
        #expect(senderContents.contains("AXHelpers.setValue(composer, \"\")"))
        #expect(senderContents.contains("AXHelpers.perform(control, kAXPressAction as String)"))
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

        let stateStore = root.appendingPathComponent("Sources/KakaoCore/State/StateStore.swift")
        let stateContents = try String(contentsOf: stateStore, encoding: .utf8)
        #expect(stateContents.contains(
            "WHERE log_id = 9223372036854775807"
        ))
        #expect(stateContents.contains(
            "guard logID > 0, logID < Int64.max"
        ))
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

    @Test("background window discovery never activates KakaoTalk")
    func backgroundWindowDiscovery() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helpers = root.appendingPathComponent("Sources/KakaoCore/Automation/AXHelpers.swift")
        let contents = try String(contentsOf: helpers, encoding: .utf8)
        #expect(contents.contains("kAXWindowsAttribute"))
        #expect(contents.contains("declared.allSatisfy({ role($0) == kAXWindowRole as String })"))
        #expect(contents.contains("children(app).filter"))
        #expect(contents.contains("kAXWindowRole"))
        #expect(!contents.contains("NSRunningApplication"))
        #expect(!contents.contains("kAXRaiseAction"))
        #expect(contents.contains("identifier(element) == \"_NS:87\""))
        #expect(contents.contains("let elements = chatRowChromeElements(row)"))
        #expect(contents.contains("if identifier(child) == \"_NS:87\""))
        #expect(!contents.contains("_NS:91"))
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
