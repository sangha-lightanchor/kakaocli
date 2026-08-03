import Foundation

public struct KakaoDatabaseConfiguration: Sendable {
    public let path: String
    public let key: String?
}

public enum DatabaseLocator {
    public static func resolve(
        databasePath: String? = nil,
        key: String? = nil,
        userID: Int? = nil
    ) throws -> KakaoDatabaseConfiguration {
        if let databasePath {
            return KakaoDatabaseConfiguration(path: databasePath, key: key)
        }
        let uuid = try DeviceInfo.platformUUID()
        let storedKey = key ?? SourceDatabaseKeyStore.load()
        if let detectedID = try? (userID ?? DeviceInfo.userId()) {
            let name = KeyDerivation.databaseName(userId: detectedID, uuid: uuid)
            for path in ["\(DeviceInfo.containerPath)/\(name)", "\(DeviceInfo.containerPath)/\(name).db"]
            where FileManager.default.fileExists(atPath: path) {
                return KakaoDatabaseConfiguration(
                    path: path,
                    key: storedKey ?? KeyDerivation.secureKey(userId: detectedID, uuid: uuid)
                )
            }
        }

        guard let discovered = DeviceInfo.discoverDatabaseFile() else {
            throw KakaoError.databaseNotFound(DeviceInfo.containerPath)
        }
        if let storedKey {
            let reader = DatabaseReader(databasePath: discovered)
            if reader.tryOpen(key: storedKey) {
                reader.close()
                return KakaoDatabaseConfiguration(path: discovered, key: storedKey)
            }
        }
        var candidates = (try? DeviceInfo.userId()).map { [$0] } ?? []
        candidates += DeviceInfo.candidateUserIds().filter { !candidates.contains($0) }
        if let userID, !candidates.contains(userID) { candidates.insert(userID, at: 0) }
        for candidate in candidates {
            let derived = KeyDerivation.secureKey(userId: candidate, uuid: uuid)
            let reader = DatabaseReader(databasePath: discovered)
            if reader.tryOpen(key: derived) {
                reader.close()
                return KakaoDatabaseConfiguration(path: discovered, key: derived)
            }
        }
        throw KakaoError.databaseOpenFailed("No locally derived key opened the KakaoTalk database")
    }
}

private enum SourceDatabaseKeyStore {
    static func load() -> String? {
        KeychainCLI.read(service: "com.kakaocli.sqlcipher", account: "default")
    }
}
