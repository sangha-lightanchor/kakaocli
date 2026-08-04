import Darwin
import Foundation

public struct KakaoDatabaseConfiguration: Sendable {
    public let path: String
    public let key: String?
}

public enum DatabaseLocator {
    /// Resolves the active local database. The cache contains only a validated
    /// path and user ID; the SQLCipher key is derived in memory on each launch.
    /// Expensive hash recovery is opt-in so ordinary reads never brute-force.
    public static func resolve(
        databasePath: String? = nil,
        key: String? = nil,
        userID: Int? = nil,
        deviceUUID: String? = nil,
        allowExpensiveRecovery: Bool = false,
        refreshCache: Bool = false,
        cacheURL: URL? = nil
    ) throws -> KakaoDatabaseConfiguration {
        let cache = DatabaseIdentityCache(url: cacheURL ?? DatabaseIdentityCache.defaultURL)
        let overridePath = databasePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }

        if let key {
            guard let path = overridePath ?? DeviceInfo.discoverDatabaseFile() else {
                throw KakaoError.databaseNotFound(DeviceInfo.containerPath)
            }
            // Explicit keys are one-shot overrides. They are never written to
            // the identity cache, even when a user ID was also supplied.
            return KakaoDatabaseConfiguration(path: path, key: key)
        }

        if let overridePath {
            let plaintext = KakaoDatabaseConfiguration(path: overridePath, key: nil)
            if configurationOpens(plaintext) { return plaintext }
        }

        let uuid = try deviceUUID ?? DeviceInfo.platformUUID()
        let cachedIdentity = refreshCache ? nil : cache.load()
        if let cachedIdentity {
            let identity = DatabaseIdentity(
                path: overridePath ?? cachedIdentity.path,
                userID: cachedIdentity.userID
            )
            let configuration = derivedConfiguration(identity: identity, uuid: uuid)
            if configurationOpens(configuration) { return configuration }
        }

        let discovered = overridePath ?? DeviceInfo.discoverDatabaseFile()
        var candidates: [Int] = []
        appendUnique(userID, to: &candidates)
        appendUnique(cachedIdentity?.userID, to: &candidates)
        appendUnique(try? DeviceInfo.userId(allowExpensiveRecovery: false), to: &candidates)
        for candidate in DeviceInfo.candidateUserIds() {
            appendUnique(candidate, to: &candidates)
        }
        if allowExpensiveRecovery {
            appendUnique(
                try? DeviceInfo.userId(allowExpensiveRecovery: true),
                to: &candidates
            )
        }

        for candidate in candidates {
            let derivedKey = KeyDerivation.secureKey(userId: candidate, uuid: uuid)
            let name = KeyDerivation.databaseName(userId: candidate, uuid: uuid)
            let candidatePaths: [String]
            if let overridePath {
                candidatePaths = [overridePath]
            } else {
                candidatePaths = [
                    "\(DeviceInfo.containerPath)/\(name)",
                    "\(DeviceInfo.containerPath)/\(name).db",
                    discovered,
                ].compactMap { $0 }
            }
            for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
                let configuration = KakaoDatabaseConfiguration(path: path, key: derivedKey)
                if configurationOpens(configuration) {
                    try cache.store(DatabaseIdentity(path: path, userID: candidate))
                    return configuration
                }
            }
        }

        guard discovered != nil else {
            throw KakaoError.databaseNotFound(DeviceInfo.containerPath)
        }
        let guidance = allowExpensiveRecovery
            ? "No locally derived key opened the KakaoTalk database"
            : "Database identity is not cached; run `kakaocli auth --refresh` once"
        throw KakaoError.databaseOpenFailed(guidance)
    }

    public static func clearCachedResolution(cacheURL: URL? = nil) {
        DatabaseIdentityCache(url: cacheURL ?? DatabaseIdentityCache.defaultURL).clear()
    }

    private static func derivedConfiguration(
        identity: DatabaseIdentity,
        uuid: String
    ) -> KakaoDatabaseConfiguration {
        KakaoDatabaseConfiguration(
            path: identity.path,
            key: KeyDerivation.secureKey(userId: identity.userID, uuid: uuid)
        )
    }

    private static func configurationOpens(_ configuration: KakaoDatabaseConfiguration) -> Bool {
        let reader = DatabaseReader(databasePath: configuration.path)
        defer { reader.close() }
        if let key = configuration.key { return reader.tryOpen(key: key) }
        do {
            try reader.open()
            _ = try reader.schema()
            return true
        } catch {
            return false
        }
    }

    private static func appendUnique(_ value: Int?, to values: inout [Int]) {
        guard let value, value > 0, !values.contains(value) else { return }
        values.append(value)
    }
}

struct DatabaseIdentity: Codable, Equatable, Sendable {
    let path: String
    let userID: Int
}

final class DatabaseIdentityCache: @unchecked Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kakaocli/source-database.json")

    private let url: URL

    init(url: URL) { self.url = url }

    func load() -> DatabaseIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0,
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(DatabaseIdentity.self, from: data),
              value.userID > 0,
              value.path.hasPrefix("/") else { return nil }
        return value
    }

    func store(_ identity: DatabaseIdentity) throws {
        guard identity.userID > 0 else {
            throw KakaoError.databaseOpenFailed(
                "Database identity cache user ID must be positive"
            )
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              parentInfo.st_uid == geteuid(),
              parentInfo.st_mode & S_IFMT == S_IFDIR,
              chmod(parent.path, 0o700) == 0 else {
            throw KakaoError.databaseOpenFailed(
                "Could not secure the database identity cache directory"
            )
        }
        let standardized = DatabaseIdentity(
            path: URL(fileURLWithPath: identity.path).standardizedFileURL.path,
            userID: identity.userID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(standardized).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else {
            throw KakaoError.databaseOpenFailed(
                "Could not secure the database identity cache"
            )
        }
    }

    func clear() {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
