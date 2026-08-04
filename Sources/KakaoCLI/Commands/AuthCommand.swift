import ArgumentParser
import Foundation
import KakaoCore

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "auth", abstract: "Verify read-only KakaoTalk database access")

    @OptionGroup var database: DatabaseOptions

    @Flag(name: .long, help: "Run explicit expensive identity recovery and refresh the user-only local identity cache")
    var refresh = false

    @Flag(name: .customLong("key-stdin"), help: "Read a one-shot SQLCipher key from stdin; never persist it")
    var keyStdin = false

    mutating func run() throws {
        guard !(refresh && keyStdin) else {
            throw ValidationError("Use --refresh for derived identity recovery or --key-stdin for a one-shot key, not both")
        }
        let suppliedKey: String?
        if keyStdin {
            let data = try readBoundedStdin(
                maximumBytes: KakaoLimits.maximumSecretBytes,
                label: "database key"
            )
            guard let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .newlines), !value.isEmpty else {
                throw ValidationError("stdin database key must be nonempty UTF-8")
            }
            suppliedKey = value
        } else {
            suppliedKey = nil
        }
        let configuration = try DatabaseLocator.resolve(
            databasePath: database.db,
            key: suppliedKey,
            allowExpensiveRecovery: refresh,
            refreshCache: refresh
        )
        let reader = DatabaseReader(databasePath: configuration.path)
        try reader.open(key: configuration.key)
        defer { reader.close() }
        print("Database access verified (\(try reader.schema().count) tables).")
    }
}
