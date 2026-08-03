import CryptoKit
import Darwin
import Foundation

public struct ChatID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public var description: String { String(rawValue) }
}

public enum SendDestination: Hashable, Codable, Sendable {
    case chatID(ChatID)
    case selfChat

    fileprivate var storageKey: String {
        switch self {
        case .chatID(let id): return "chat:\(id.rawValue)"
        case .selfChat: return "self"
        }
    }
}

public struct SendRequest: Hashable, Codable, Sendable {
    public let requestID: UUID
    public let destination: SendDestination
    public let body: String

    public init(requestID: UUID, destination: SendDestination, body: String) {
        self.requestID = requestID
        self.destination = destination
        self.body = body
    }
}

public enum SendStatus: String, Codable, Sendable {
    case confirmed
    case unknown
}

public struct SendReceipt: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let chatID: ChatID
    public let logID: Int64?
    public let status: SendStatus
}

public enum SafeSendError: Error, CustomStringConvertible {
    case invalidRequest(String)
    case chatNotFound(ChatID)
    case selfChatNotFound
    case requestIDConflict(UUID)
    case state(String)

    public var description: String {
        switch self {
        case .invalidRequest(let message), .state(let message): return message
        case .chatNotFound(let id): return "Chat ID \(id) was not found"
        case .selfChatNotFound: return "Self-chat was not found"
        case .requestIDConflict(let id): return "Request ID \(id) was already used with different content"
        }
    }
}

/// Synchronous implementation used by the CLI. The public actor below wraps
/// the same whole-transaction logic for concurrent library callers.
public final class SafeSendClient: @unchecked Sendable {
    private let database: DatabaseReader
    private let automator: KakaoAutomator
    private let paths: SendPaths
    private static let processLock = NSLock()

    public init(
        database: DatabaseReader,
        automator: KakaoAutomator = KakaoAutomator(),
        stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kakaocli", isDirectory: true)
    ) {
        self.database = database
        self.automator = automator
        self.paths = SendPaths(stateDirectory: stateDirectory)
    }

    public func send(_ request: SendRequest) throws -> SendReceipt {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let body = Data(request.body.utf8)
        guard !body.isEmpty, !body.contains(0) else {
            throw SafeSendError.invalidRequest("Message must contain non-NUL UTF-8 bytes")
        }
        try paths.prepare()
        let fileLock = try SendFileLock(path: paths.lock.path)
        try fileLock.lock()
        defer { fileLock.unlock() }

        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let store = SendReceiptStore(path: paths.receipts)
        if let stored = try store.attempt(requestID: request.requestID) {
            guard stored.destination == request.destination.storageKey, stored.bodySHA256 == bodyHash else {
                throw SafeSendError.requestIDConflict(request.requestID)
            }
            return stored.receipt
        }

        let chat: Chat
        switch request.destination {
        case .chatID(let id):
            guard let resolved = try database.chat(id: id.rawValue) else { throw SafeSendError.chatNotFound(id) }
            chat = resolved
        case .selfChat:
            guard let resolved = try database.selfChat() else { throw SafeSendError.selfChatNotFound }
            chat = resolved
        }
        guard chat.displayName != "(unknown)" else {
            throw SafeSendError.invalidRequest("The chat ID has no provable UI identity")
        }
        let highWater = try database.maxLogId(chatId: chat.id)
        let provisional = SendReceipt(
            requestID: request.requestID,
            chatID: ChatID(rawValue: chat.id),
            logID: nil,
            status: .unknown
        )
        // Persist before the irreversible UI action. A crash from this point is
        // conservatively replayed as unknown instead of risking a duplicate.
        try store.save(
            destination: request.destination.storageKey,
            bodySHA256: bodyHash,
            receipt: provisional
        )
        do {
            try automator.submit(chat: chat, message: request.body)
        } catch AutomationError.preconditionFailed(let message) {
            // The automator promises this case occurs before submission and
            // clears any composed text. Remove the provisional receipt so the
            // corrected precondition can be retried with the same request ID.
            try store.remove(requestID: request.requestID)
            throw AutomationError.preconditionFailed(message)
        } catch AutomationError.outcomeUnknown {
            return provisional
        }

        for attempt in 0..<120 {
            if let logID = try database.confirmedOutgoing(chatId: chat.id, body: body, after: highWater) {
                let receipt = SendReceipt(
                    requestID: request.requestID,
                    chatID: ChatID(rawValue: chat.id),
                    logID: logID,
                    status: .confirmed
                )
                try store.save(destination: request.destination.storageKey, bodySHA256: bodyHash, receipt: receipt)
                return receipt
            }
            if attempt < 119 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return provisional
    }
}

public actor KakaoClient {
    private let database: DatabaseReader
    private let sender: SafeSendClient

    public init(database: DatabaseReader, stateDirectory: URL? = nil) {
        self.database = database
        self.sender = SafeSendClient(
            database: database,
            stateDirectory: stateDirectory ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".kakaocli", isDirectory: true)
        )
    }

    public func listChats(limit: Int = 50) throws -> [Chat] { try database.chats(limit: limit) }
    public func messages(chatID: ChatID? = nil, since: Date? = nil, limit: Int = 50) throws -> [Message] {
        try database.messages(chatId: chatID?.rawValue, since: since, limit: limit)
    }
    public func send(_ request: SendRequest) throws -> SendReceipt { try sender.send(request) }
}

private struct SendPaths {
    let stateDirectory: URL
    var runDirectory: URL { stateDirectory.appendingPathComponent("run", isDirectory: true) }
    var lock: URL { runDirectory.appendingPathComponent("send.lock") }
    var receipts: URL { stateDirectory.appendingPathComponent("send-receipts.json") }

    func prepare() throws {
        for directory in [stateDirectory, runDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(directory.path, 0o700) == 0 else {
                throw SafeSendError.state("Could not secure send state")
            }
        }
    }
}

private final class SendFileLock {
    private let descriptor: Int32
    init(path: String) throws {
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SafeSendError.state("Could not open the send lock")
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            Darwin.close(descriptor)
            throw SafeSendError.state("Could not secure the send lock")
        }
    }
    deinit { Darwin.close(descriptor) }
    func lock() throws {
        guard flock(descriptor, LOCK_EX) == 0 else { throw SafeSendError.state("Could not acquire the send lock") }
    }
    func unlock() { _ = flock(descriptor, LOCK_UN) }
}

private struct StoredSendAttempt: Codable {
    let destination: String
    let bodySHA256: String
    let receipt: SendReceipt
}

private final class SendReceiptStore {
    private let path: URL
    init(path: URL) { self.path = path }

    func attempt(requestID: UUID) throws -> StoredSendAttempt? {
        try load()[requestID.uuidString.lowercased()]
    }

    func save(destination: String, bodySHA256: String, receipt: SendReceipt) throws {
        var values = try load()
        values[receipt.requestID.uuidString.lowercased()] = StoredSendAttempt(
            destination: destination,
            bodySHA256: bodySHA256,
            receipt: receipt
        )
        let data = try JSONEncoder().encode(values)
        try data.write(to: path, options: [.atomic])
        guard chmod(path.path, 0o600) == 0 else { throw SafeSendError.state("Could not secure send receipts") }
    }

    func remove(requestID: UUID) throws {
        var values = try load()
        values.removeValue(forKey: requestID.uuidString.lowercased())
        let data = try JSONEncoder().encode(values)
        try data.write(to: path, options: [.atomic])
        guard chmod(path.path, 0o600) == 0 else { throw SafeSendError.state("Could not secure send receipts") }
    }

    private func load() throws -> [String: StoredSendAttempt] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        return try JSONDecoder().decode(
            [String: StoredSendAttempt].self,
            from: Data(contentsOf: path)
        )
    }
}
