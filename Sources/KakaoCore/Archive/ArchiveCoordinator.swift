import Foundation

public final class ArchiveCoordinator: @unchecked Sendable {
    private let state: StateStore
    private let media: MediaArchiver
    private let webhook: GenericWebhook

    public init(state: StateStore, media: MediaArchiver, webhook: GenericWebhook) {
        self.state = state
        self.media = media
        self.webhook = webhook
    }

    @discardableResult
    public func archive(_ message: Message) throws -> Bool {
        let attachments = AttachmentNormalizer.normalize(message: message)
        guard try state.archive(message: message, attachments: attachments) else { return false }
        try media.processPending()
        try webhook.enqueue(message: message, attachments: attachments)
        try webhook.deliverPending()
        return true
    }
}
