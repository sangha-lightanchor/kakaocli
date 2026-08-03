import ArgumentParser
import KakaoCore

struct ChatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chats", abstract: "List chats and stable chat IDs")

    @Option(name: .long, help: "Filter display names locally")
    var search: String?

    @Option(name: .long, help: "Maximum chats to return")
    var limit = 50

    @Flag(name: .long, help: "Output JSON")
    var json = false

    @OptionGroup var database: DatabaseOptions

    mutating func run() async throws {
        let chats: [Chat]
        let connection = serviceConnection()
        if !database.usesOverride, connection.isAvailable {
            chats = try connection.call(
                LocalServiceRequest(method: "chats", search: search, limit: limit),
                as: [Chat].self
            )
        } else {
            chats = try await liveClient(database).listChats(search: search, limit: limit)
        }
        if json { try JSONOutput.print(chats); return }
        for chat in chats {
            let marker = chat.isSelfChat ? " [self]" : ""
            print("[\(chat.id)] \(chat.displayName)\(marker)")
        }
    }
}
