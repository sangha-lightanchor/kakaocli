import ArgumentParser
import Foundation
import KakaoCore

struct MigrationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Import a prior local archive without replaying its outbox",
        subcommands: [Legacy.self, ConfirmedReceipt.self]
    )

    struct Legacy: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "legacy")

        @Option(name: .long, help: "Prior messages/outbox SQLite path")
        var messagesDb: String

        @Option(name: .long, help: "Prior media manifest SQLite path")
        var mediaDb: String?

        @Option(name: .long, help: "Prior media archive root")
        var mediaRoot: String?

        @Flag(name: .long) var json = false
        @OptionGroup var database: DatabaseOptions

        mutating func run() throws {
            let paths = RuntimePaths()
            try paths.prepare()
            let sourceConfiguration = try DatabaseLocator.resolve(databasePath: database.db)
            let source = DatabaseReader(databasePath: sourceConfiguration.path)
            try source.open(key: sourceConfiguration.key)
            defer { source.close() }
            let state = try StateStore(
                path: paths.stateDatabase.path,
                key: try StateKeyStore.loadOrCreate(at: paths.stateKey),
                archiveRoot: paths.archiveRoot.path
            )
            defer { state.close() }
            let report = try LegacyMigrator(
                state: state,
                archiveRoot: paths.archiveRoot,
                sourceDatabase: source
            ).migrate(
                messagesDatabase: URL(fileURLWithPath: messagesDb),
                mediaDatabase: mediaDb.map { URL(fileURLWithPath: $0) },
                mediaRoot: mediaRoot.map { URL(fileURLWithPath: $0) }
            )
            if json { try JSONOutput.print(report) }
            else {
                print("Imported \(report.messagesImported) messages, \(report.mediaCompleteImported) complete media objects, and \(report.mediaExpiredImported) expired records; skipped \(report.pendingOutboxSkipped) pending webhook batches.")
            }
        }
    }

    struct ConfirmedReceipt: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "confirmed-receipt",
            abstract: "Restore idempotency from an exact outgoing source-database row without UI"
        )

        @Option(name: .long, help: "Previously used request UUID")
        var requestId: String

        @Option(name: .long, help: "Exact chat ID containing the outgoing row")
        var chatId: Int64

        @Option(name: .long, help: "Exact outgoing source-database log ID")
        var logId: Int64

        @Flag(name: [.customLong("self")], help: "Record the destination as self-chat")
        var selfChat = false

        @Flag(name: .long, help: "Read the exact prior message bytes from stdin")
        var stdin = false

        @Flag(name: .long, help: "Output JSON")
        var json = false

        @OptionGroup var database: DatabaseOptions

        mutating func run() throws {
            guard let requestID = UUID(uuidString: requestId) else {
                throw ValidationError("--request-id must be a UUID")
            }
            guard chatId > 0, logId > 0 else {
                throw ValidationError("--chat-id and --log-id must be positive")
            }
            let bodyData = try readBoundedStdin(
                maximumBytes: KakaoLimits.maximumSendBodyBytes,
                label: "confirmed message stdin"
            )
            guard let body = String(data: bodyData, encoding: .utf8) else {
                throw ValidationError("stdin must be valid UTF-8")
            }

            let paths = RuntimePaths()
            try paths.prepare()
            let sourceConfiguration = try DatabaseLocator.resolve(databasePath: database.db)
            let source = DatabaseReader(databasePath: sourceConfiguration.path)
            try source.open(key: sourceConfiguration.key)
            defer { source.close() }
            let state = try StateStore(
                path: paths.stateDatabase.path,
                key: try StateKeyStore.loadOrCreate(at: paths.stateKey),
                archiveRoot: paths.archiveRoot.path
            )
            defer { state.close() }

            let destination: SendDestination = selfChat
                ? .selfChat
                : .chatID(ChatID(rawValue: chatId))
            let receipt = try ConfirmedReceiptImporter(
                database: source,
                state: state
            ).importReceipt(
                request: SendRequest(
                    requestID: requestID,
                    destination: destination,
                    body: body
                ),
                chatID: ChatID(rawValue: chatId),
                logID: logId
            )

            if json { try JSONOutput.print(receipt) }
            else {
                print("confirmed request_id=\(receipt.requestID.uuidString) chat_id=\(receipt.chatID.rawValue) log_id=\(logId)")
            }
        }
    }
}
