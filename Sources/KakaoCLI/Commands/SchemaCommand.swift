import ArgumentParser
import Foundation
import KakaoCore

struct SchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Dump the database schema (for reverse engineering)"
    )

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Flag(name: .customLong("key-stdin"), help: "Read a one-shot database key from stdin")
    var keyStdin = false

    func run() throws {
        let reader = try openDatabase(
            dbPath: db,
            key: databaseKeyFromStdin(ifRequested: keyStdin)
        )
        defer { reader.close() }

        let tables = try reader.schema()
        if tables.isEmpty {
            print("No tables found (database may be encrypted).")
            return
        }

        for table in tables {
            print("-- \(table.name)")
            print("\(table.sql);")
            print()
        }
    }
}
