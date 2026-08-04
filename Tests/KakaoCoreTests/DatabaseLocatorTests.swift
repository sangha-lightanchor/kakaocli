import Darwin
import Foundation
import Testing
@testable import KakaoCore

@Suite("Prompt-free database resolution")
struct DatabaseLocatorTests {
    @Test("identity cache is mode 0600 and never stores a SQLCipher key")
    func cachePermissionsAndContents() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state/source-database.json")
        let cache = DatabaseIdentityCache(url: url)
        let identity = DatabaseIdentity(
            path: "/tmp/../tmp/example.sqlite3",
            userID: 123
        )

        try cache.store(identity)

        let loaded = try #require(cache.load())
        #expect(loaded.path == "/tmp/example.sqlite3")
        #expect(loaded.userID == 123)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        #expect(Set(object.keys) == Set(["path", "userID"]))
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .localizedCaseInsensitiveContains("key"))
    }

    @Test("insecure cache permissions fail closed")
    func rejectsInsecureCache() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state/source-database.json")
        let cache = DatabaseIdentityCache(url: url)
        try cache.store(DatabaseIdentity(path: "/tmp/example.sqlite3", userID: 123))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
        #expect(cache.load() == nil)
    }

    @Test("path overrides are prompt-free and one-shot keys are never cached")
    func pathOverrides() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("source.sqlite3")
        try createSQLiteDatabase(at: database)
        let cache = root.appendingPathComponent("identity.json")

        let plaintext = try DatabaseLocator.resolve(
            databasePath: database.path,
            deviceUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            cacheURL: cache
        )
        #expect(plaintext.path == database.path)
        #expect(plaintext.key == nil)

        let oneShot = try DatabaseLocator.resolve(
            databasePath: database.path,
            key: "one-shot-secret",
            deviceUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            cacheURL: cache
        )
        #expect(oneShot.path == database.path)
        #expect(oneShot.key == "one-shot-secret")
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("ordinary user-ID lookup keeps hash recovery opt-in")
    func recoveryIsOptIn() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deviceInfo = root.appendingPathComponent(
            "Sources/KakaoCore/Database/DeviceInfo.swift"
        )
        let contents = try String(contentsOf: deviceInfo, encoding: .utf8)
        #expect(contents.contains(
            "public static func userId(allowExpensiveRecovery: Bool = false)"
        ))
        #expect(contents.contains("if allowExpensiveRecovery"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func createSQLiteDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, "CREATE TABLE probe(value INTEGER);"]
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
