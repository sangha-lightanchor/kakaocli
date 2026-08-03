import CryptoKit
import Foundation

public struct WebhookAttachment: Codable, Sendable {
    public let id: String
    public let kind: String
    public let name: String?
    public let mimeType: String?
    public let expectedBytes: Int64?
    public let width: Int?
    public let height: Int?
    public let durationMilliseconds: Int64?
    public let archiveStatus: String
    public let sha256: String?
}

public struct WebhookEnvelope: Codable, Sendable {
    public let eventID: String
    public let logID: String
    public let chatID: String
    public let senderID: String
    public let text: String?
    public let messageType: Int
    public let timestamp: Date
    public let isFromMe: Bool
    public let attachments: [WebhookAttachment]
    public let archive: ArchiveStatus
}

public protocol WebhookTransporting: Sendable {
    func post(url: URL, bearerToken: String?, eventID: String, payload: Data) throws
}

public struct URLSessionWebhookTransport: WebhookTransporting {
    public init() {}

    public func post(url: URL, bearerToken: String?, eventID: String, payload: Data) throws {
        let scheme = url.scheme?.lowercased()
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw KakaoClientError.invalidRequest("Webhook must use HTTPS (HTTP is allowed only on loopback)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("kakaocli/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(eventID, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(eventID, forHTTPHeaderField: "X-Kakaocli-Event-ID")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            if let error { failure = error; return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                failure = KakaoClientError.state("Webhook returned a non-success response")
                return
            }
        }
        task.resume()
        semaphore.wait()
        if let failure { throw failure }
    }
}

public final class GenericWebhook: @unchecked Sendable {
    public static let URLKey = "webhook.url"
    public static let bearerKey = "webhook.bearer"

    private let state: StateStore
    private let transport: WebhookTransporting

    public init(state: StateStore, transport: WebhookTransporting = URLSessionWebhookTransport()) {
        self.state = state
        self.transport = transport
    }

    public func enqueue(message: Message, attachments: [NormalizedAttachment]) throws {
        guard try state.configuration(key: Self.URLKey) != nil else { return }
        let delivery = Dictionary(uniqueKeysWithValues: try state.attachmentDelivery(logID: message.id).map {
            ($0.id, $0)
        })
        let eventID = SHA256.hash(data: Data("message:\(message.id)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let envelope = WebhookEnvelope(
            eventID: eventID,
            logID: String(message.id),
            chatID: message.chatId.description,
            senderID: String(message.senderId),
            text: message.text,
            messageType: message.type.rawValue,
            timestamp: message.createdAt,
            isFromMe: message.isFromMe,
            attachments: attachments.map {
                WebhookAttachment(
                    id: $0.id,
                    kind: $0.kind.rawValue,
                    name: $0.name,
                    mimeType: $0.mimeType,
                    expectedBytes: $0.expectedBytes,
                    width: $0.width,
                    height: $0.height,
                    durationMilliseconds: $0.durationMilliseconds,
                    archiveStatus: delivery[$0.id]?.status ?? "metadata_only",
                    sha256: delivery[$0.id]?.sha256
                )
            },
            archive: try state.archiveStatus()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try state.enqueueWebhook(eventID: eventID, payload: encoder.encode(envelope))
    }

    public func deliverPending(limit: Int = 20) throws {
        guard let rawURL = try state.configuration(key: Self.URLKey), let url = URL(string: rawURL) else {
            return
        }
        let token = try state.configuration(key: Self.bearerKey)
        for pending in try state.pendingWebhooks(limit: limit) {
            do {
                try transport.post(url: url, bearerToken: token, eventID: pending.eventID, payload: pending.payload)
                try state.markWebhookDelivered(eventID: pending.eventID)
            } catch {
                try state.markWebhookFailed(
                    eventID: pending.eventID,
                    error: String(describing: error),
                    attempts: pending.attempts + 1
                )
            }
        }
    }
}
