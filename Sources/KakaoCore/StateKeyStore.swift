import Foundation
import Security

public enum StateKeyStore {
    private static let service = "com.kakaocli.state"
    private static let account = "database-key"

    public static func loadOrCreate() throws -> String {
        if let key = KeychainCLI.read(service: service, account: account), key.count == 64 {
            return key
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KakaoClientError.state("Could not generate the state encryption key")
        }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        guard KeychainCLI.write(service: service, account: account, value: key) else {
            throw KakaoClientError.state("Could not store the state encryption key")
        }
        return key
    }
}

enum KeychainCLI {
    static func read(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }

    static func write(service: String, account: String, value: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password", "-U", "-s", service, "-a", account,
            "-w", value,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
