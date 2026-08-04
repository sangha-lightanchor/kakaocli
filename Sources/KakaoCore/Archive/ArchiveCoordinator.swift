import Foundation

public final class ArchiveCoordinator: @unchecked Sendable {
    private let state: StateStore
    private let media: MediaArchiver
    private let webhook: GenericWebhook
    private let workerQueue = DispatchQueue(label: "com.kakaocli.archive-worker", qos: .utility)
    private let workerLock = NSLock()
    private var workerRunning = false

    public init(state: StateStore, media: MediaArchiver, webhook: GenericWebhook) {
        self.state = state
        self.media = media
        self.webhook = webhook
    }

    @discardableResult
    public func archive(_ message: Message) throws -> Bool {
        let attachments = AttachmentNormalizer.normalize(message: message)
        guard try state.archive(message: message, attachments: attachments) else { return false }
        try webhook.enqueue(message: message, attachments: attachments)
        schedulePendingWork()
        return true
    }

    /// Metadata ingestion remains fast; downloads and webhooks run on one
    /// bounded serial worker instead of blocking KakaoClient's actor.
    public func schedulePendingWork() {
        workerLock.lock()
        guard !workerRunning else {
            workerLock.unlock()
            return
        }
        workerRunning = true
        workerLock.unlock()
        workerQueue.async { [weak self] in self?.drainPendingWork() }
    }

    /// Exposed for deterministic reconciliation/tests without adding a second
    /// concurrent archive worker.
    public func processPendingWorkNow() throws {
        let changed = try media.processPending(limit: 20)
        for logID in changed { try webhook.enqueueArchiveUpdate(logID: logID) }
        try webhook.deliverPending(limit: 20)
    }

    private func drainPendingWork() {
        defer {
            workerLock.lock()
            workerRunning = false
            workerLock.unlock()
        }
        do {
            for _ in 0..<100 {
                let changed = try media.processPending(limit: 20)
                for logID in changed { try webhook.enqueueArchiveUpdate(logID: logID) }
                try webhook.deliverPending(limit: 20)
                if changed.isEmpty { break }
            }
        } catch {
            // Durable pending rows retain the work. The next DB event or
            // reconciliation schedules another bounded drain.
        }
    }
}
