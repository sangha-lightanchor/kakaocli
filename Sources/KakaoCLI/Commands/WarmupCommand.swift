import ArgumentParser
import KakaoCore

struct WarmupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "warmup",
        abstract: "Verify one already-open exact room without composing or sending"
    )

    @Option(name: .long, help: "Exact chat ID")
    var chatId: Int64?

    @Flag(name: [.customLong("self")], help: "Warm self-chat")
    var selfChat = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    @OptionGroup var database: DatabaseOptions

    mutating func run() async throws {
        guard (chatId != nil) != selfChat else {
            throw ValidationError("Specify exactly one of --chat-id or --self")
        }
        if let chatId, chatId <= 0 { throw ValidationError("--chat-id must be positive") }
        let destination: SendDestination = selfChat
            ? .selfChat
            : .chatID(ChatID(rawValue: chatId!))

        let receipt: RoomWarmupReceipt
        let connection = serviceConnection()
        if !database.usesOverride, connection.isAvailable {
            try requireCurrentService(connection)
            receipt = try connection.call(
                LocalServiceRequest(method: "warmup_v2", destination: destination),
                as: RoomWarmupReceipt.self
            )
        } else {
            receipt = try await liveClient(database).warmup(destination: destination)
        }

        if json { try JSONOutput.print(receipt) }
        else { print("\(receipt.status.rawValue) chat_id=\(receipt.chatID)") }
    }
}
