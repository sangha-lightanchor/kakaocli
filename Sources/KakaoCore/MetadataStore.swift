import Darwin
import Foundation

/// Persistent metadata store for KakaoTalk chat names and harvest info.
/// Stored at ~/.kakaocli/metadata.json
public final class MetadataStore {

    public struct ChatInfo: Codable {
        public var displayName: String
        public var memberCount: Int?
        public var chatType: Int?
        public var lastHarvested: Date?
        public var messageCount: Int?
    }

    private let directory: URL
    private let file: URL
    private var chats: [String: ChatInfo]

    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kakaocli", isDirectory: true)
        self.file = self.directory.appendingPathComponent("metadata.json")
        try Self.prepareDirectory(self.directory)

        var fileInfo = stat()
        if lstat(file.path, &fileInfo) != 0 {
            guard errno == ENOENT else { throw MetadataStoreError.unsafePath }
            chats = [:]
            return
        }
        let data = try Self.readSecureFile(file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            chats = try decoder.decode([String: ChatInfo].self, from: data)
        } catch {
            throw MetadataStoreError.corrupt
        }
    }

    public func name(for chatId: Int64) -> String? {
        chats[String(chatId)]?.displayName
    }

    public func info(for chatId: Int64) -> ChatInfo? {
        chats[String(chatId)]
    }

    public func update(chatId: Int64, name: String, memberCount: Int? = nil,
                       chatType: Int? = nil, messageCount: Int? = nil) {
        let key = String(chatId)
        var existing = chats[key] ?? ChatInfo(displayName: name)
        existing.displayName = name
        existing.lastHarvested = Date()
        if let memberCount { existing.memberCount = memberCount }
        if let chatType { existing.chatType = chatType }
        if let messageCount { existing.messageCount = messageCount }
        chats[key] = existing
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(chats)
        try Self.writeSecureFile(data, to: file, in: directory)
    }

    public var allChats: [String: ChatInfo] {
        chats
    }

    public var count: Int { chats.count }

    private static func prepareDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw MetadataStoreError.unsafePath }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard lstat(directory.path, &info) == 0 else {
                throw MetadataStoreError.unsafePath
            }
        }
        guard info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR,
              chmod(directory.path, 0o700) == 0 else {
            throw MetadataStoreError.unsafePath
        }
    }

    private static func readSecureFile(_ file: URL) throws -> Data {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MetadataStoreError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= 16 * 1_024 * 1_024,
              fchmod(descriptor, 0o600) == 0 else {
            throw MetadataStoreError.unsafePath
        }
        return handle.readDataToEndOfFile()
    }

    private static func writeSecureFile(_ data: Data, to file: URL, in directory: URL) throws {
        let temporary = directory.appendingPathComponent(".metadata.\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw MetadataStoreError.writeFailed }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove { _ = unlink(temporary.path) }
        }

        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll,
              fchmod(descriptor, 0o600) == 0,
              fsync(descriptor) == 0,
              rename(temporary.path, file.path) == 0 else {
            throw MetadataStoreError.writeFailed
        }
        shouldRemove = false

        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard directoryDescriptor >= 0 else { throw MetadataStoreError.writeFailed }
        defer { Darwin.close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw MetadataStoreError.writeFailed
        }
    }
}

public enum MetadataStoreError: Error, CustomStringConvertible {
    case unsafePath
    case corrupt
    case writeFailed

    public var description: String {
        switch self {
        case .unsafePath:
            return "Metadata must use a user-owned regular file in a user-owned directory"
        case .corrupt:
            return "Metadata is corrupt or incompatible"
        case .writeFailed:
            return "Metadata could not be persisted securely"
        }
    }
}
