import ArgumentParser
import Foundation
import KakaoCore

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Safely send stdin to an exact chat ID or self-chat"
    )

    @Option(name: .long, help: "Exact database chat ID")
    var chatId: Int64?

    @Flag(name: [.customLong("self")], help: "Send to self-chat")
    var selfChat = false

    @Flag(name: .long, help: "Read the message from stdin (the default and only input mode)")
    var stdin = false

    @Option(name: .long, help: "Caller-supplied UUID for durable idempotency")
    var requestId: String

    @Flag(name: .long, help: "Output a JSON receipt")
    var json = false

    @Flag(name: .long, help: "Validate without invoking KakaoTalk")
    var dryRun = false

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    func run() throws {
        guard (chatId != nil) != selfChat else {
            throw ValidationError("Specify exactly one of --chat-id or --self")
        }
        guard let requestUUID = UUID(uuidString: requestId) else {
            throw ValidationError("--request-id must be a UUID")
        }
        if let chatId, chatId <= 0 { throw ValidationError("--chat-id must be positive") }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            throw ValidationError("stdin must contain valid, nonempty UTF-8")
        }
        let destination: SendDestination = selfChat
            ? .selfChat
            : .chatID(ChatID(rawValue: chatId!))
        if dryRun {
            struct DryRun: Encodable {
                let requestID: UUID
                let destination: String
                let bytes: Int
            }
            let value = DryRun(
                requestID: requestUUID,
                destination: selfChat ? "self" : "chat:\(chatId!)",
                bytes: data.count
            )
            if json { try JSONOutput.print(value) }
            else { print("DRY RUN request_id=\(requestUUID) destination=\(value.destination) bytes=\(data.count)") }
            return
        }

        let reader = try openDatabase(dbPath: db, key: key)
        defer { reader.close() }
        let receipt = try SafeSendClient(database: reader).send(
            SendRequest(requestID: requestUUID, destination: destination, body: body)
        )
        if json { try JSONOutput.print(receipt) }
        else {
            print("\(receipt.status.rawValue) request_id=\(receipt.requestID) chat_id=\(receipt.chatID) log_id=\(receipt.logID.map(String.init) ?? "null")")
        }
    }
}
