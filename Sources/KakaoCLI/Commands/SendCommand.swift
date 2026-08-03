import ArgumentParser
import Foundation
import KakaoCore

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message via UI automation"
    )

    @Argument(help: "Chat name to send to (substring match), or any value with --me")
    var chat: String

    @Argument(help: "Message text to send")
    var message: String

    @Flag(name: [.customLong("me")], help: "Send to self-chat (나와의 채팅) regardless of chat argument")
    var selfChat = false

    @Flag(name: .long, help: "Show what would happen without actually sending")
    var dryRun = false

    @Flag(name: .long, help: "Use legacy foreground UI automation, which may launch or activate KakaoTalk")
    var foreground = false

    func run() throws {
        let automator = KakaoAutomator()
        let target = selfChat ? "self-chat" : chat
        if dryRun {
            print("DRY RUN: Would send to '\(target)': \(message)")
            let mode = foreground ? "foreground UI automation" : "background-only UI automation"
            print("Mode: \(mode)")
            print("Steps: find chat '\(target)' → set composer value → invoke Send")
            return
        }
        try automator.sendMessage(
            to: chat,
            message: message,
            selfChat: selfChat,
            mode: foreground ? .foreground : .backgroundOnly
        )
        print("Message sent to '\(target)'.")
    }
}
