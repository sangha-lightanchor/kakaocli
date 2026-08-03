import Foundation

/// A stable KakaoTalk chat identifier. Names are display-only and are never
/// accepted as send destinations.
public struct ChatID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init?(_ description: String) {
        guard let value = Int64(description), value > 0 else { return nil }
        self.rawValue = value
    }

    public var description: String { String(rawValue) }
}

/// A KakaoTalk chat room read from the local database.
public struct Chat: Codable, Sendable, Equatable {
    public let id: ChatID
    public let type: ChatType
    public let displayName: String
    public let memberCount: Int
    public let lastMessageId: Int64?
    public let lastMessageAt: Date?
    public let unreadCount: Int
    public let isSelfChat: Bool

    public init(
        id: ChatID,
        type: ChatType,
        displayName: String,
        memberCount: Int,
        lastMessageId: Int64?,
        lastMessageAt: Date?,
        unreadCount: Int,
        isSelfChat: Bool = false
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.memberCount = memberCount
        self.lastMessageId = lastMessageId
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.isSelfChat = isSelfChat
    }

    public enum ChatType: String, Codable, Sendable {
        case direct
        case group
        case openChat = "open"
        case selfChat = "self"
        case unknown
    }
}

extension Chat.ChatType {
    static func from(rawInt: Int) -> Self {
        switch rawInt {
        case 0: return .direct
        case 1: return .group
        case 5: return .selfChat
        default: return .unknown
        }
    }
}
