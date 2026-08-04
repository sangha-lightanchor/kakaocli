import ArgumentParser
import Foundation
import KakaoCore

struct MigrationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Import a prior local archive without replaying its outbox",
        subcommands: [Legacy.self]
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
                key: try StateKeyStore.loadOrCreate(),
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
}
