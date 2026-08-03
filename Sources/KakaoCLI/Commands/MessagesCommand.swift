import ArgumentParser
import Foundation
import KakaoCore

struct MessagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "messages", abstract: "Read messages by stable chat ID")

    @Option(name: .long, help: "Exact chat ID")
    var chatId: Int64?

    @Option(name: .long, help: "Only messages since a duration such as 1h or 7d")
    var since: String?

    @Option(name: .long, help: "Maximum messages to return")
    var limit = 50

    @Flag(name: .long, help: "Output JSON")
    var json = false

    @OptionGroup var database: DatabaseOptions

    mutating func run() async throws {
        let id = chatId.map { ChatID(rawValue: $0) }
        let date = parseDuration(since)
        if since != nil, date == nil {
            throw ValidationError("--since must be a duration such as 1h, 24h, or 7d")
        }
        let messages: [Message]
        let connection = serviceConnection()
        if !database.usesOverride, connection.isAvailable {
            messages = try connection.call(
                LocalServiceRequest(method: "messages", limit: limit, chatID: id, since: date),
                as: [Message].self
            )
        } else {
            messages = try await liveClient(database).messages(chatID: id, since: date, limit: limit)
        }
        if json { try JSONOutput.print(messages); return }
        let formatter = ISO8601DateFormatter()
        for message in messages.reversed() {
            let sender = message.isFromMe ? "Me" : (message.senderName ?? "Unknown")
            print("\(formatter.string(from: message.createdAt)) \(sender): \(message.text ?? "[\(message.type)]")")
        }
    }
}
