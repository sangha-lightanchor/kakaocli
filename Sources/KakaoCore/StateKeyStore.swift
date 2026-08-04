import Foundation
import LocalAuthentication
import Security

public enum StateKeyStore {
    private static let service = "com.kakaocli.state"
    private static let account = "database-key"

    public static func loadOrCreate() throws -> String {
        try loadOrCreate(store: SystemStateSecretStore(service: service, account: account))
    }

    static func loadOrCreate(store: StateSecretStoring) throws -> String {
        switch store.read() {
        case .value(let key):
            return try validate(key)
        case .unavailable(let status):
            throw KakaoClientError.state(
                "The existing state encryption key is inaccessible without interaction (OSStatus \(status)); refusing to replace it"
            )
        case .notFound:
            break
        }

        let generated = try generate()
        switch store.insert(generated) {
        case .inserted:
            return generated
        case .unavailable(let status):
            throw KakaoClientError.state(
                "Could not store the state encryption key (OSStatus \(status))"
            )
        case .duplicate:
            // Another process won the creation race. Read and use that exact
            // key; never overwrite it with this process's generated candidate.
            switch store.read() {
            case .value(let key): return try validate(key)
            case .notFound:
                throw KakaoClientError.state("State encryption key creation raced and then disappeared")
            case .unavailable(let status):
                throw KakaoClientError.state(
                    "The concurrently created state key is inaccessible (OSStatus \(status))"
                )
            }
        }
    }

    private static func validate(_ key: String) throws -> String {
        guard key.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw KakaoClientError.state(
                "The existing state encryption key has an invalid format; refusing to replace it"
            )
        }
        return key.lowercased()
    }

    private static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KakaoClientError.state("Could not generate the state encryption key")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum SecretReadResult: Equatable {
    case value(String)
    case notFound
    case unavailable(OSStatus)
}

enum SecretInsertResult: Equatable {
    case inserted
    case duplicate
    case unavailable(OSStatus)
}

protocol StateSecretStoring {
    func read() -> SecretReadResult
    func insert(_ value: String) -> SecretInsertResult
}

private struct SystemStateSecretStore: StateSecretStoring {
    let service: String
    let account: String

    func read() -> SecretReadResult {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return .unavailable(errSecDecode)
            }
            return .value(value)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
    }

    func insert(_ value: String) -> SecretInsertResult {
        var item = baseQuery
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        switch status {
        case errSecSuccess: return .inserted
        case errSecDuplicateItem: return .duplicate
        default: return .unavailable(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
