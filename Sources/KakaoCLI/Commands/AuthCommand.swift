import ArgumentParser
import KakaoCore

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "auth", abstract: "Verify read-only KakaoTalk database access")

    @OptionGroup var database: DatabaseOptions

    mutating func run() throws {
        let configuration = try DatabaseLocator.resolve(databasePath: database.db, key: database.key)
        let reader = DatabaseReader(databasePath: configuration.path)
        try reader.open(key: configuration.key)
        defer { reader.close() }
        print("Database access verified (\(try reader.schema().count) tables).")
    }
}
