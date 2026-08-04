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
    public let archive: WebhookArchiveStatus
}

/// Deliberately excludes archiveRoot and every other machine-local path.
public struct WebhookArchiveStatus: Codable, Sendable, Equatable {
    public let allowedChatCount: Int
    public let messageCount: Int
    public let attachmentCount: Int
    public let objectCount: Int
    public let pendingDownloadCount: Int
    public let pausedLowDiskCount: Int
    public let expiredAttachmentCount: Int
    public let failedDownloadCount: Int
    public let pendingWebhookCount: Int

    init(_ status: ArchiveStatus) {
        allowedChatCount = status.allowedChatCount
        messageCount = status.messageCount
        attachmentCount = status.attachmentCount
        objectCount = status.objectCount
        pendingDownloadCount = status.pendingDownloadCount
        pausedLowDiskCount = status.pausedLowDiskCount
        expiredAttachmentCount = status.expiredAttachmentCount
        failedDownloadCount = status.failedDownloadCount
        pendingWebhookCount = status.pendingWebhookCount
    }
}

public enum WebhookEndpointPolicy {
    public static func permits(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased() ?? ""
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        return url.user == nil && url.password == nil && !host.isEmpty
            && (scheme == "https" || (scheme == "http" && isLoopback))
    }
}

public protocol WebhookTransporting: Sendable {
    func post(url: URL, bearerToken: String?, eventID: String, payload: Data) throws
}

public struct URLSessionWebhookTransport: WebhookTransporting {
    public init() {}

    public func post(url: URL, bearerToken: String?, eventID: String, payload: Data) throws {
        guard WebhookEndpointPolicy.permits(url) else {
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: RejectWebhookRedirects(),
            delegateQueue: nil
        )
        let task = session.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            if let error { failure = error; return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                failure = KakaoClientError.state("Webhook returned a non-success response")
                return
            }
        }
        task.resume()
        semaphore.wait()
        session.finishTasksAndInvalidate()
        if let failure { throw failure }
    }
}

private final class RejectWebhookRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // POST bodies and bearer credentials must never cross an origin or be
        // silently downgraded. Configuration should point at the final URL.
        completionHandler(nil)
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

    @discardableResult
    public func enqueue(message: Message, attachments: [NormalizedAttachment]) throws -> Bool {
        let eventID = baseEventID(logID: message.id)
        let payload = try payload(message: message, attachments: attachments, eventID: eventID)
        return try state.completeArchiveIngestion(
            chatID: message.chatId,
            logID: message.id,
            webhookEventID: eventID,
            webhookPayload: payload
        )
    }

    /// Refreshes an undelivered message event after archive work. If the base
    /// event was already delivered, a deterministic status-update event is
    /// added instead so newly available hashes are not silently lost.
    public func enqueueArchiveUpdate(logID: Int64) throws {
        guard try state.configuration(key: Self.URLKey) != nil,
              let record = try state.archivedWebhookRecord(logID: logID) else { return }
        let base = baseEventID(logID: logID)
        let delivery = try state.attachmentDelivery(logID: logID)
        let eventID: String
        if try state.webhookWasDelivered(eventID: base) {
            let version = delivery
                .sorted { $0.id < $1.id }
                .map { "\($0.id):\($0.status):\($0.sha256 ?? "")" }
                .joined(separator: "|")
            eventID = digest("archive:\(logID):\(version)")
        } else {
            eventID = base
        }
        try state.enqueueWebhook(
            eventID: eventID,
            payload: payload(message: record.message, attachments: record.attachments, eventID: eventID)
        )
    }

    private func payload(message: Message, attachments: [NormalizedAttachment], eventID: String) throws -> Data {
        let delivery = Dictionary(uniqueKeysWithValues: try state.attachmentDelivery(logID: message.id).map {
            ($0.id, $0)
        })
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
                    name: safeAttachmentName($0.name),
                    mimeType: $0.mimeType,
                    expectedBytes: $0.expectedBytes,
                    width: $0.width,
                    height: $0.height,
                    durationMilliseconds: $0.durationMilliseconds,
                    archiveStatus: delivery[$0.id]?.status ?? "metadata_only",
                    sha256: delivery[$0.id]?.sha256
                )
            },
            archive: WebhookArchiveStatus(try state.archiveStatus())
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    private func baseEventID(logID: Int64) -> String { digest("message:\(logID)") }

    private func safeAttachmentName(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let decoded = value.removingPercentEncoding ?? value
        let windowsDrive = decoded.count >= 2
            && decoded[decoded.index(after: decoded.startIndex)] == ":"
            && decoded.first?.isLetter == true
        guard !windowsDrive,
              decoded != ".", decoded != "..",
              !decoded.hasPrefix("~"),
              !decoded.contains("/"), !decoded.contains("\\"),
              !decoded.localizedCaseInsensitiveContains("://"),
              decoded.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func deliverPending(limit: Int = 20) throws {
        guard let configuration = try state.webhookConfiguration(),
              let url = URL(string: configuration.url) else {
            return
        }
        for pending in try state.pendingWebhooks(limit: limit) {
            do {
                try transport.post(
                    url: url,
                    bearerToken: configuration.bearerToken,
                    eventID: pending.eventID,
                    payload: pending.payload
                )
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
