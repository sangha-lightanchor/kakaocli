import Foundation

public enum SendDestination: Hashable, Codable, Sendable {
    case chatID(ChatID)
    case selfChat

    var storageKey: String {
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

    public init(requestID: UUID, chatID: ChatID, logID: Int64?, status: SendStatus) {
        self.requestID = requestID
        self.chatID = chatID
        self.logID = logID
        self.status = status
    }
}

public enum KakaoEvent: Sendable, Equatable {
    case message(Message)
    case archiveStatus(ArchiveStatus)
}

public struct ArchiveStatus: Codable, Sendable, Equatable {
    public let allowedChatCount: Int
    public let messageCount: Int
    public let attachmentCount: Int
    public let objectCount: Int
    public let pendingDownloadCount: Int
    public let pausedLowDiskCount: Int
    public let expiredAttachmentCount: Int
    public let failedDownloadCount: Int
    public let pendingWebhookCount: Int
    public let archiveRoot: String

    public init(
        allowedChatCount: Int,
        messageCount: Int,
        attachmentCount: Int,
        objectCount: Int,
        pendingDownloadCount: Int,
        pausedLowDiskCount: Int,
        expiredAttachmentCount: Int,
        failedDownloadCount: Int,
        pendingWebhookCount: Int,
        archiveRoot: String
    ) {
        self.allowedChatCount = allowedChatCount
        self.messageCount = messageCount
        self.attachmentCount = attachmentCount
        self.objectCount = objectCount
        self.pendingDownloadCount = pendingDownloadCount
        self.pausedLowDiskCount = pausedLowDiskCount
        self.expiredAttachmentCount = expiredAttachmentCount
        self.failedDownloadCount = failedDownloadCount
        self.pendingWebhookCount = pendingWebhookCount
        self.archiveRoot = archiveRoot
    }
}

public enum KakaoClientError: Error, CustomStringConvertible, Equatable {
    case invalidRequest(String)
    case chatNotFound(ChatID)
    case selfChatNotFound
    case requestIDConflict(UUID)
    case uiPrecondition(String)
    case state(String)

    public var description: String {
        switch self {
        case .invalidRequest(let message): return message
        case .chatNotFound(let id): return "Chat ID \(id) was not found"
        case .selfChatNotFound: return "Self-chat was not found"
        case .requestIDConflict(let id):
            return "Request ID \(id.uuidString) was already used with different content"
        case .uiPrecondition(let message): return message
        case .state(let message): return message
        }
    }
}
