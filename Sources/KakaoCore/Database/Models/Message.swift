import Foundation

/// A KakaoTalk message read from the local database.
public struct Message: Codable, Sendable, Equatable {
    public let id: Int64
    public let chatId: ChatID
    public let senderId: Int64
    public let senderName: String?
    public let text: String?
    public let type: MessageType
    public let createdAt: Date
    public let isFromMe: Bool
    /// Raw attachment metadata. It is retained only inside the encrypted state
    /// database and is never included in webhook payloads.
    public let rawAttachment: String?

    public init(
        id: Int64,
        chatId: ChatID,
        senderId: Int64,
        senderName: String?,
        text: String?,
        type: MessageType,
        createdAt: Date,
        isFromMe: Bool,
        rawAttachment: String? = nil
    ) {
        self.id = id
        self.chatId = chatId
        self.senderId = senderId
        self.senderName = senderName
        self.text = text
        self.type = type
        self.createdAt = createdAt
        self.isFromMe = isFromMe
        self.rawAttachment = rawAttachment
    }

    public enum MessageType: Int, Codable, Sendable {
        case text = 1
        case photo = 2
        case video = 3
        case voice = 4
        case sticker = 5
        case file = 6
        case location = 7
        case system = 0
        case unknown = -1

        public init(rawValue: Int) {
            switch rawValue {
            case 1: self = .text
            case 2: self = .photo
            case 3: self = .video
            case 4: self = .voice
            case 5: self = .sticker
            case 6: self = .file
            case 7: self = .location
            case 0: self = .system
            default: self = .unknown
            }
        }
    }
}
