import Foundation
import Testing
@testable import KakaoCore

@Suite("Security hardening")
struct SecurityHardeningTests {
    @Test("raw query accepts one read statement and rejects writes, attach, and trailing SQL")
    func rawQueryIsStrictlyReadOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("source.sqlite3")
        try createSQLiteDatabase(at: database)

        let reader = DatabaseReader(databasePath: database.path)
        try reader.open()
        defer { reader.close() }
        let rows = try reader.rawQuery("SELECT value FROM probe")
        #expect(rows.count == 1)
        #expect(rows[0][0] as? Int64 == 1)

        #expect(throws: KakaoError.self) {
            try reader.rawQuery("CREATE TABLE forbidden(value INTEGER)")
        }
        let attached = root.appendingPathComponent("attached.sqlite3")
        #expect(throws: KakaoError.self) {
            try reader.rawQuery("ATTACH DATABASE '\(attached.path)' AS external")
        }
        #expect(!FileManager.default.fileExists(atPath: attached.path))
        #expect(throws: KakaoError.self) {
            try reader.rawQuery("SELECT 1; SELECT 2")
        }

        let symlink = root.appendingPathComponent("database-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: database)
        let linkedReader = DatabaseReader(databasePath: symlink.path)
        #expect(throws: KakaoError.self) { try linkedReader.open() }
    }

    @Test("SQLCipher keys are typed and CLI secrets are stdin-only")
    func keyHandlingSourceGuard() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let reader = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/KakaoCore/Database/DatabaseReader.swift"
            ),
            encoding: .utf8
        )
        #expect(!reader.contains("PRAGMA KEY"))
        #expect(reader.contains("sqlite3_key"))
        #expect(reader.contains("lstat(databasePath"))
        #expect(reader.contains("S_IFREG"))
        #expect(reader.contains("sqlite3_stmt_readonly"))

        let commandNames = [
            "AuthCommand.swift", "ChatsCommand.swift", "HarvestCommand.swift",
            "MessagesCommand.swift", "QueryCommand.swift", "SchemaCommand.swift",
            "SearchCommand.swift", "SyncCommand.swift",
        ]
        for name in commandNames {
            let contents = try String(
                contentsOf: repository.appendingPathComponent(
                    "Sources/KakaoCLI/Commands/\(name)"
                ),
                encoding: .utf8
            )
            #expect(!contents.contains("var key: String?"))
            #expect(!contents.contains("Database encryption key"))
            #expect(contents.contains("key-stdin"))
        }
    }

    @Test("remote webhooks require HTTPS and never accept URL credentials")
    func webhookEndpoints() throws {
        for value in [
            "https://example.com/hook",
            "http://localhost:8080/hook",
            "http://127.0.0.1:8080/hook",
            "http://[::1]:8080/hook",
        ] {
            #expect(WebhookPublisher.isAllowedEndpoint(try #require(URL(string: value))))
        }
        for value in [
            "http://example.com/hook",
            "ftp://example.com/hook",
            "https://user:secret@example.com/hook",
            "file:///tmp/hook",
        ] {
            #expect(!WebhookPublisher.isAllowedEndpoint(try #require(URL(string: value))))
        }
        let secureRedirect = URLRequest(
            url: try #require(URL(string: "https://example.com/next"))
        )
        #expect(WebhookRedirectDelegate.validatedRedirect(secureRedirect) != nil)
        let downgradedRedirect = URLRequest(
            url: try #require(URL(string: "http://example.com/next"))
        )
        #expect(WebhookRedirectDelegate.validatedRedirect(downgradedRedirect) == nil)
    }

    @Test("harvest metadata is private, durable, and rejects symlinked state")
    func secureMetadataStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        let store = try MetadataStore(directory: state)
        store.update(chatId: 42, name: "private chat")
        try store.save()

        var directoryInfo = stat()
        var fileInfo = stat()
        #expect(lstat(state.path, &directoryInfo) == 0)
        #expect(directoryInfo.st_mode & 0o777 == 0o700)
        let file = state.appendingPathComponent("metadata.json")
        #expect(lstat(file.path, &fileInfo) == 0)
        #expect(fileInfo.st_mode & 0o777 == 0o600)
        #expect(try MetadataStore(directory: state).name(for: 42) == "private chat")

        let linkedState = root.appendingPathComponent("linked-state")
        try FileManager.default.createSymbolicLink(at: linkedState, withDestinationURL: state)
        #expect(throws: MetadataStoreError.self) {
            try MetadataStore(directory: linkedState)
        }
    }

    @Test("safe sender bounds Accessibility messaging")
    func accessibilityTimeoutSourceGuard() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let automator = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/KakaoCore/Automation/KakaoAutomator.swift"
            ),
            encoding: .utf8
        )
        #expect(automator.contains("AXUIElementSetMessagingTimeout(app, 0.5)"))
        #expect(!automator.contains("CGEvent("))
        #expect(!automator.contains("postToPid"))
        #expect(!automator.contains("selectRow"))
        #expect(!automator.contains("AXHelpers.focus"))

        let helpers = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/KakaoCore/Automation/AXHelpers.swift"
            ),
            encoding: .utf8
        )
        #expect(helpers.contains("kAXVisibleRowsAttribute"))
        #expect(helpers.contains("rows.count <= 64"))
    }

    private func createSQLiteDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, "CREATE TABLE probe(value INTEGER); INSERT INTO probe VALUES (1);"]
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw KakaoError.databaseOpenFailed(
                String(
                    decoding: error.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
            )
        }
    }
}
