import Darwin
import Foundation

/// Stores the state-database key in a user-only local file. The source
/// database key is unrelated and continues to be derived in memory.
public enum StateKeyStore {
    public static func loadOrCreate(
        at url: URL = RuntimePaths().stateKey
    ) throws -> String {
        try validateParentDirectory(of: url)
        if let existing = try readExisting(at: url) {
            return existing
        }

        let generated = generate()
        return try install(generated, at: url)
    }

    private static func validateParentDirectory(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        var metadata = stat()
        guard lstat(parent.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            throw KakaoClientError.state(
                "Refusing an insecure or foreign-owned state-key directory: \(parent.path)"
            )
        }
    }

    private static func readExisting(at url: URL) throws -> String? {
        var pathMetadata = stat()
        guard lstat(url.path, &pathMetadata) == 0 else {
            if errno == ENOENT { return nil }
            throw KakaoClientError.state("Could not inspect the state encryption key")
        }
        try validateKeyMetadata(pathMetadata)

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw KakaoClientError.state("Could not securely open the state encryption key")
        }
        defer { Darwin.close(descriptor) }

        var descriptorMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0,
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino else {
            throw KakaoClientError.state("The state encryption key changed while it was being opened")
        }
        try validateKeyMetadata(descriptorMetadata)

        let maximumBytes = 65
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        var total = 0
        while total < maximumBytes {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: total),
                    maximumBytes - total
                )
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw KakaoClientError.state("Could not read the state encryption key")
            }
            total += count
        }
        guard total == 64 else {
            throw KakaoClientError.state(
                "The state encryption key has an invalid length; refusing to replace it"
            )
        }
        return try validate(Array(bytes.prefix(64)))
    }

    private static func install(_ key: String, at url: URL) throws -> String {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw KakaoClientError.state("Could not securely create the state encryption key")
        }

        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary { unlink(temporary.path) }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw KakaoClientError.state("Could not secure the state encryption key")
        }
        let bytes = Array(key.utf8)
        let byteCount = bytes.count
        var written = 0
        while written < byteCount {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: written),
                    byteCount - written
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw KakaoClientError.state("Could not write the state encryption key")
            }
            guard count > 0 else {
                throw KakaoClientError.state("State encryption key write made no progress")
            }
            written += count
        }
        guard fsync(descriptor) == 0 else {
            throw KakaoClientError.state("Could not durably store the state encryption key")
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw KakaoClientError.state("Could not verify the state encryption key")
        }
        try validateKeyMetadata(metadata)

        let renameResult = renameatx_np(
            AT_FDCWD,
            temporary.path,
            AT_FDCWD,
            url.path,
            UInt32(RENAME_EXCL)
        )
        if renameResult == 0 {
            shouldRemoveTemporary = false
            try syncDirectory(parent)
        } else if errno != EEXIST {
            throw KakaoClientError.state("Could not atomically install the state encryption key")
        }

        guard let installed = try readExisting(at: url) else {
            throw KakaoClientError.state("The state encryption key disappeared during creation")
        }
        return installed
    }

    private static func validateKeyMetadata(_ metadata: stat) throws {
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_nlink == 1,
              metadata.st_size == 64 else {
            throw KakaoClientError.state(
                "The state encryption key is not a user-owned mode-0600 regular 64-byte file; refusing to replace it"
            )
        }
    }

    private static func validate(_ bytes: [UInt8]) throws -> String {
        guard bytes.count == 64,
              bytes.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }),
              let key = String(bytes: bytes, encoding: .utf8) else {
            throw KakaoClientError.state(
                "The state encryption key has an invalid format; refusing to replace it"
            )
        }
        return key.lowercased()
    }

    private static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw KakaoClientError.state("Could not open the state-key directory for synchronization")
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw KakaoClientError.state("Could not synchronize the state-key directory")
        }
    }
}
