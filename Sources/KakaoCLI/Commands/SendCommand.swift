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

    @Flag(name: .long, help: "Verify the exact open background room without composing or sending")
    var preflight = false

    func run() throws {
        guard (chatId != nil) != selfChat else {
            throw ValidationError("Specify exactly one of --chat-id or --self")
        }
        guard !(dryRun && preflight) else {
            throw ValidationError("Specify at most one of --dry-run or --preflight")
        }
        guard let requestUUID = UUID(uuidString: requestId) else {
            throw ValidationError("--request-id must be a UUID")
        }
        if let chatId, chatId <= 0 { throw ValidationError("--chat-id must be positive") }
        var data = Data()
        while data.count <= SafeSendClient.maximumBodyBytes {
            let remaining = SafeSendClient.maximumBodyBytes + 1 - data.count
            guard remaining > 0 else { break }
            let chunk = try FileHandle.standardInput.read(
                upToCount: min(8 * 1_024, remaining)
            ) ?? Data()
            guard !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= SafeSendClient.maximumBodyBytes else {
            throw ValidationError(
                "stdin exceeds \(SafeSendClient.maximumBodyBytes) UTF-8 bytes"
            )
        }
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

        // The send command never accepts source-database keys in process
        // arguments. Normal database access derives the key in memory.
        let reader = try openDatabase(dbPath: nil, key: nil)
        defer { reader.close() }
        let client = SafeSendClient(database: reader)
        if preflight {
            struct Preflight: Encodable {
                let destination: String
                let chatID: ChatID
                let ready: Bool
            }
            let resolved = try client.preflight(destination: destination)
            let value = Preflight(
                destination: selfChat ? "self" : "chat:\(chatId!)",
                chatID: resolved,
                ready: true
            )
            if json { try JSONOutput.print(value) }
            else { print("READY destination=\(value.destination) chat_id=\(resolved)") }
            return
        }
        let receipt = try client.send(
            SendRequest(requestID: requestUUID, destination: destination, body: body)
        )
        if json { try JSONOutput.print(receipt) }
        else {
            print("\(receipt.status.rawValue) request_id=\(receipt.requestID) chat_id=\(receipt.chatID) log_id=\(receipt.logID.map(String.init) ?? "null")")
        }
    }
}
