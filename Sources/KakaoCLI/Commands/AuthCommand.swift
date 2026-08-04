import ArgumentParser
import Foundation
import KakaoCore

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Verify database access and cache prompt-free local identity"
    )

    @Option(name: .long, help: "Path to database file (auto-detected if not set)")
    var db: String?

    @Option(name: .long, help: "Override user ID instead of reading preferences")
    var userId: Int?

    @Option(name: .long, help: "Override device UUID instead of reading ioreg")
    var uuid: String?

    @Flag(
        name: .long,
        help: "Run explicit expensive identity recovery and refresh the mode-0600 local cache"
    )
    var refresh = false

    @Flag(
        name: .customLong("key-stdin"),
        help: "Read a one-shot SQLCipher key from stdin; never persist it"
    )
    var keyStdin = false

    @Flag(name: .long, help: "Show the resolved database path (never the key)")
    var verbose = false

    func run() throws {
        guard !(refresh && keyStdin) else {
            throw ValidationError(
                "Use --refresh for derived identity recovery or --key-stdin for a one-shot key, not both"
            )
        }
        guard !keyStdin || userId == nil else {
            throw ValidationError("--user-id is not used with a one-shot --key-stdin key")
        }

        let suppliedKey = try databaseKeyFromStdin(ifRequested: keyStdin)
        let resolved = try DatabaseLocator.resolve(
            databasePath: db,
            key: suppliedKey,
            userID: userId,
            deviceUUID: uuid,
            allowExpensiveRecovery: refresh,
            refreshCache: refresh
        )
        let reader = DatabaseReader(databasePath: resolved.path)
        try reader.open(key: resolved.key)
        defer { reader.close() }
        let tableCount = try reader.schema().count
        if verbose { print("Database: \(resolved.path)") }
        print("Database access verified (\(tableCount) tables).")
    }

}
