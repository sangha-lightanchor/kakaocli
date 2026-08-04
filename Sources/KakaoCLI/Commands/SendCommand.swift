import ArgumentParser
import Foundation
import KakaoCore

struct SendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Safely send stdin to an exact chat ID or self-chat"
    )

    @Option(name: .long, help: "Exact chat ID")
    var chatId: Int64?

    @Flag(name: [.customLong("self")], help: "Send to self-chat")
    var selfChat = false

    @Flag(name: .long, help: "Read message bytes from stdin (the default and only input mode)")
    var stdin = false

    @Option(name: .long, help: "Caller-supplied UUID used for durable idempotency")
    var requestId: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    @Flag(name: .long, help: "Validate and describe the request without sending")
    var dryRun = false

    @OptionGroup var database: DatabaseOptions

    mutating func run() async throws {
        guard (chatId != nil) != selfChat else {
            throw ValidationError("Specify exactly one of --chat-id or --self")
        }
        guard let requestUUID = UUID(uuidString: requestId) else {
            throw ValidationError("--request-id must be a UUID")
        }
        if let chatId, chatId <= 0 { throw ValidationError("--chat-id must be positive") }
        let data = try readBoundedStdin(
            maximumBytes: KakaoLimits.maximumSendBodyBytes,
            label: "message stdin"
        )
        guard let body = String(data: data, encoding: .utf8) else {
            throw ValidationError("stdin must be valid UTF-8")
        }
        try KakaoLimits.validateSendBody(body)
        let destination: SendDestination = selfChat
            ? .selfChat
            : .chatID(ChatID(rawValue: chatId!))
        let request = SendRequest(requestID: requestUUID, destination: destination, body: body)

        if dryRun {
            struct DryRun: Encodable { let requestID: UUID; let destination: String; let bytes: Int }
            let summary = DryRun(
                requestID: requestUUID,
                destination: selfChat ? "self" : "chat:\(chatId!)",
                bytes: data.count
            )
            if json { try JSONOutput.print(summary) }
            else { print("DRY RUN request_id=\(requestUUID.uuidString) destination=\(summary.destination) bytes=\(data.count)") }
            return
        }

        let receipt: SendReceipt
        let connection = serviceConnection()
        if !database.usesOverride, connection.isAvailable {
            receipt = try connection.call(
                LocalServiceRequest(method: "send", sendRequest: request),
                as: SendReceipt.self
            )
        } else {
            receipt = try await liveClient(database).send(request)
        }
        if json { try JSONOutput.print(receipt) }
        else {
            let log = receipt.logID.map(String.init) ?? "null"
            print("\(receipt.status.rawValue) request_id=\(receipt.requestID.uuidString) chat_id=\(receipt.chatID) log_id=\(log)")
        }
    }
}
