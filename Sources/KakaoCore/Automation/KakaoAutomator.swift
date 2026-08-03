import AppKit
import ApplicationServices
import Foundation

public enum KakaoSendMode: Sendable {
    /// Never activate KakaoTalk. Fail if its main window is not already rendered.
    case backgroundOnly

    /// Use the legacy auto-launching, foreground UI automation path.
    case foreground
}

/// Automates KakaoTalk UI for sending messages.
public final class KakaoAutomator {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Send a message to a chat. Background-only mode is the default and never
    /// activates KakaoTalk. Foreground mode remains an explicit setup/recovery
    /// path when KakaoTalk has no rendered main window.
    public func sendMessage(
        to chatName: String,
        message: String,
        selfChat: Bool = false,
        mode: KakaoSendMode = .backgroundOnly
    ) throws {
        switch mode {
        case .backgroundOnly:
            try sendMessageInBackground(to: chatName, message: message, selfChat: selfChat)
        case .foreground:
            try sendMessageInForeground(to: chatName, message: message, selfChat: selfChat)
        }
    }

    private func sendMessageInBackground(
        to chatName: String,
        message: String,
        selfChat: Bool
    ) throws {
        guard !message.isEmpty else {
            throw AutomationError.sendFailed("Message cannot be empty")
        }
        guard let runningApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleId
        ).first else {
            throw AutomationError.backgroundUnavailable(
                "KakaoTalk is not running. Open it once, then leave its main window available in the background."
            )
        }

        let app = AXUIElementCreateApplication(runningApp.processIdentifier)
        var windows = AXHelpers.windows(app)
        guard let mainWindow = windows.first(where: {
            AXHelpers.identifier($0) == "Main Window"
        }) else {
            throw AutomationError.backgroundUnavailable(
                "KakaoTalk's main window is not rendered. Open it once, then switch back to your working app."
            )
        }

        // Close stale chat windows so a later action cannot land in the wrong
        // room. AX close-button actions work without app activation.
        for window in windows where AXHelpers.identifier(window) != "Main Window" {
            _ = AXHelpers.closeWindow(window)
        }
        if windows.count > 1 {
            Thread.sleep(forTimeInterval: 0.3)
        }

        // KakaoTalk exposes its sidebar tabs without AXPress actions. A mouse
        // event posted directly to KakaoTalk's PID changes tabs without moving
        // the user's cursor or activating the app.
        if let chatroomsTab =
            AXHelpers.findFirst(mainWindow, role: "AXButton", identifier: "chatrooms") ??
            AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") {
            AXHelpers.clickElement(
                chatroomsTab,
                processIdentifier: runningApp.processIdentifier
            )
            Thread.sleep(forTimeInterval: 0.3)
        }

        guard let table = AXHelpers.chatListTable(mainWindow) else {
            throw AutomationError.backgroundUnavailable(
                "The chat list is not available to background automation."
            )
        }

        let row: AXUIElement
        if selfChat {
            guard let selfRow = AXHelpers.findSelfChatRow(table) else {
                throw AutomationError.chatNotFound("self-chat (나와의 채팅)")
            }
            row = selfRow
        } else {
            guard let chatRow = AXHelpers.findChatRow(table, chatName: chatName) else {
                throw AutomationError.chatNotFound(chatName)
            }
            row = chatRow
        }

        guard AXHelpers.selectRow(row, in: table) else {
            throw AutomationError.backgroundUnavailable(
                "The destination row could not be selected without foreground UI automation."
            )
        }
        _ = AXHelpers.focus(table)
        AXHelpers.pressKey(
            keyCode: 36,
            processIdentifier: runningApp.processIdentifier
        )

        var chatWindow: AXUIElement?
        let windowDeadline = Date().addingTimeInterval(5.0)
        while Date() < windowDeadline {
            Thread.sleep(forTimeInterval: 0.2)
            windows = AXHelpers.windows(app)
            chatWindow = windows.first(where: {
                AXHelpers.identifier($0) != "Main Window"
            })
            if chatWindow != nil { break }
        }
        guard let chatWindow else {
            throw AutomationError.backgroundUnavailable(
                "The chat window did not open through background automation."
            )
        }

        var inputField: AXUIElement?
        var didSend = false
        defer {
            if !didSend, let inputField {
                _ = AXHelpers.setValue(inputField, "")
            }
            _ = AXHelpers.closeWindow(chatWindow)
        }

        guard let resolvedInput = findInputField(in: chatWindow) else {
            throw AutomationError.inputFieldNotFound
        }
        inputField = resolvedInput
        guard AXHelpers.setValue(resolvedInput, message),
              AXHelpers.value(resolvedInput) == message else {
            throw AutomationError.sendFailed(
                "KakaoTalk did not accept the message through its background composer."
            )
        }

        var sendButton: AXUIElement?
        let buttonDeadline = Date().addingTimeInterval(2.0)
        while Date() < buttonDeadline {
            sendButton = findSendButton(in: chatWindow, relativeTo: resolvedInput)
            if sendButton != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let sendButton else {
            throw AutomationError.sendFailed(
                "KakaoTalk did not expose an enabled background Send control."
            )
        }

        // KakaoTalk may report AXError.cannotComplete even after honoring this
        // action, so verify the observable result instead of trusting the code.
        _ = AXHelpers.performAction(sendButton, kAXPressAction as String)
        let sendDeadline = Date().addingTimeInterval(3.0)
        while Date() < sendDeadline {
            if AXHelpers.value(resolvedInput)?.isEmpty == true {
                didSend = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard didSend else {
            throw AutomationError.sendFailed(
                "The background Send action did not clear the composer; delivery was not confirmed."
            )
        }

        // Give KakaoTalk's send handler time to finish before closing the room.
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func sendMessageInForeground(
        to chatName: String,
        message: String,
        selfChat: Bool
    ) throws {
        // 1. Ensure KakaoTalk is running and logged in
        let stateBefore = AppLifecycle.detectState()
        try AppLifecycle.ensureReady(credentials: CredentialStore())
        if stateBefore != .loggedIn {
            Thread.sleep(forTimeInterval: 2.0)
        }

        // 2. Activate KakaoTalk and get windows
        try AXHelpers.activateApp(bundleId: Self.bundleId)
        let app = try AXHelpers.appElement(bundleId: Self.bundleId)

        let windows = AXHelpers.windows(app)
        guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
            throw AutomationError.noWindows
        }

        // 3. Close any existing chat windows to avoid sending to the wrong one
        for w in windows where AXHelpers.identifier(w) != "Main Window" {
            _ = AXHelpers.closeWindow(w)
        }
        if windows.count > 1 {
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 4. Ensure we're on the Chats tab
        if let chatroomsTab = AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") {
            _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 5. Find the chat row in the list
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            throw AutomationError.chatNotFound(chatName)
        }

        let row: AXUIElement
        if selfChat {
            guard let selfRow = AXHelpers.findSelfChatRow(table) else {
                throw AutomationError.chatNotFound("self-chat (나와의 채팅)")
            }
            row = selfRow
        } else {
            guard let chatRow = AXHelpers.findChatRow(table, chatName: chatName) else {
                throw AutomationError.chatNotFound(chatName)
            }
            row = chatRow
        }

        // 6. Open the chat via AX row selection + Enter (works even when off-screen).
        //    Falls back to scroll-into-view + double-click if selection fails.
        var opened = false
        if AXHelpers.selectRow(row, in: table) {
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Enter to open
            Thread.sleep(forTimeInterval: 0.5)
            let checkWindows = AXHelpers.windows(app)
            opened = checkWindows.contains { AXHelpers.identifier($0) != "Main Window" }
        }
        if !opened {
            if let scrollArea = AXHelpers.chatListScrollArea(mainWindow) {
                _ = AXHelpers.scrollRowToVisible(row, in: scrollArea)
                Thread.sleep(forTimeInterval: 0.3)
            }
            AXHelpers.doubleClickElement(row)
        }

        // 7. Wait for the chat window to appear
        var chatWindow: AXUIElement?
        let windowDeadline = Date().addingTimeInterval(5.0)
        while Date() < windowDeadline {
            Thread.sleep(forTimeInterval: 0.5)
            let updatedWindows = AXHelpers.windows(app)
            chatWindow = updatedWindows.first(where: { AXHelpers.identifier($0) != "Main Window" })
            if chatWindow != nil { break }
        }
        guard let chatWindow else {
            throw AutomationError.inputFieldNotFound
        }

        // 8. Find the message input field
        guard let inputField = findInputField(in: chatWindow) else {
            throw AutomationError.inputFieldNotFound
        }

        // 9. Focus and type the message
        _ = AXHelpers.performAction(chatWindow, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.3)
        AXHelpers.clickElement(inputField)
        Thread.sleep(forTimeInterval: 0.3)

        if AXHelpers.setValue(inputField, message) {
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Return key
        } else {
            _ = AXHelpers.focus(inputField)
            Thread.sleep(forTimeInterval: 0.1)
            AXHelpers.typeText(message)
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Return key
        }

        // 10. Close the chat window
        Thread.sleep(forTimeInterval: 0.3)
        _ = AXHelpers.closeWindow(chatWindow)
    }

    /// Find the message input AXTextArea in a chat window.
    /// Prefer KakaoTalk's current composer ID/description, then fall back to a
    /// settable AXTextArea so hierarchy changes do not break sending.
    private func findInputField(in window: AXUIElement) -> AXUIElement? {
        if let currentComposer = AXHelpers.findFirst(
            window,
            role: "AXTextArea",
            identifier: "_NS:51"
        ), AXHelpers.isAttributeSettable(currentComposer, kAXValueAttribute as String) {
            return currentComposer
        }

        for textArea in AXHelpers.findAll(window, role: "AXTextArea") {
            let description = AXHelpers.description(textArea) ?? ""
            if (description.localizedCaseInsensitiveContains("enter a message") ||
                description.contains("메시지")) &&
                AXHelpers.isAttributeSettable(textArea, kAXValueAttribute as String) {
                return textArea
            }
        }

        for child in AXHelpers.children(window) {
            guard AXHelpers.role(child) == "AXScrollArea" else { continue }
            // The message list scroll area contains an AXTable; the input one doesn't
            let hasTable = AXHelpers.children(child).contains { AXHelpers.role($0) == "AXTable" }
            if !hasTable {
                // This scroll area should contain the input AXTextArea
                for subchild in AXHelpers.children(child) {
                    if AXHelpers.role(subchild) == "AXTextArea" &&
                        AXHelpers.isAttributeSettable(subchild, kAXValueAttribute as String) {
                        return subchild
                    }
                }
            }
        }
        return nil
    }

    private func findSendButton(
        in window: AXUIElement,
        relativeTo inputField: AXUIElement
    ) -> AXUIElement? {
        guard let inputPosition = AXHelpers.position(inputField),
              let inputSize = AXHelpers.size(inputField) else {
            return nil
        }

        let windowChildren = AXHelpers.children(window)
        let buttons: [BackgroundSendControlCandidate] = windowChildren.enumerated().compactMap { index, element in
            guard AXHelpers.role(element) == "AXButton" else { return nil }
            let label = [AXHelpers.title(element), AXHelpers.description(element)]
                .compactMap { $0 }
                .joined(separator: " ")
            return BackgroundSendControlCandidate(
                index: index,
                label: label,
                enabled: AXHelpers.boolAttribute(element, kAXEnabledAttribute as String) == true,
                supportsPress: AXHelpers.actionNames(element).contains(kAXPressAction as String),
                position: AXHelpers.position(element)
            )
        }
        let inputFrame = CGRect(origin: inputPosition, size: inputSize)
        guard let selectedIndex = BackgroundSendSelector.sendControlIndex(
            from: buttons,
            inputFrame: inputFrame
        ) else {
            return nil
        }
        return windowChildren[selectedIndex]
    }

}

public enum AutomationError: Error, CustomStringConvertible {
    case noWindows
    case chatNotFound(String)
    case inputFieldNotFound
    case backgroundUnavailable(String)
    case sendFailed(String)

    public var description: String {
        switch self {
        case .noWindows:
            return "KakaoTalk has no open windows"
        case .chatNotFound(let name):
            return "Chat '\(name)' not found in the chat list"
        case .inputFieldNotFound:
            return "Could not find the message input field"
        case .backgroundUnavailable(let msg):
            return "Background send unavailable: \(msg) Use foreground mode only if focus stealing is acceptable."
        case .sendFailed(let msg):
            return "Failed to send message: \(msg)"
        }
    }
}
