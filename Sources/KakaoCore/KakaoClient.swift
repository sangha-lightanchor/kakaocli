import Foundation

/// Concurrency-safe public API. One actor owns the persistent read-only Kakao
/// connection, chat cache, send queue, event high-water mark, and archive work.
public actor KakaoClient {
    private let database: DatabaseReader
    private let state: StateStore
    private let sender: SafeSendCoordinator
    private let archive: ArchiveCoordinator
    private let monitor: DatabaseChangeMonitor
    private var chatCache: [ChatID: Chat] = [:]
    private var eventHighWatermark: Int64
    private var continuations: [UUID: AsyncThrowingStream<KakaoEvent, Error>.Continuation] = [:]
    private var monitorStarted = false

    public init(
        database: DatabaseReader,
        state: StateStore,
        sender: SafeSendCoordinator,
        archive: ArchiveCoordinator,
        monitor: DatabaseChangeMonitor
    ) throws {
        self.database = database
        self.state = state
        self.sender = sender
        self.archive = archive
        self.monitor = monitor
        self.eventHighWatermark = try database.maxLogID(chatID: nil)
    }

    public static func live(
        databasePath: String? = nil,
        databaseKey: String? = nil,
        paths: RuntimePaths = RuntimePaths()
    ) throws -> KakaoClient {
        try paths.prepare()
        let configuration = try DatabaseLocator.resolve(databasePath: databasePath, key: databaseKey)
        let database = DatabaseReader(databasePath: configuration.path)
        try database.open(key: configuration.key)
        let state = try StateStore(
            path: paths.stateDatabase.path,
            key: try StateKeyStore.loadOrCreate(at: paths.stateKey),
            archiveRoot: paths.archiveRoot.path
        )
        let sender = SafeSendCoordinator(
            database: database,
            state: state,
            ui: SafeKakaoSender(),
            transactionLock: SendTransactionLock(path: paths.lock.path)
        )
        let media = MediaArchiver(state: state, root: paths.archiveRoot)
        let webhook = GenericWebhook(state: state)
        return try KakaoClient(
            database: database,
            state: state,
            sender: sender,
            archive: ArchiveCoordinator(state: state, media: media, webhook: webhook),
            monitor: DatabaseChangeMonitor(databasePath: configuration.path)
        )
    }

    public func listChats(search: String? = nil, limit: Int = 50) throws -> [Chat] {
        let limit = try KakaoLimits.validatedResultLimit(limit, maximum: KakaoLimits.maximumChatResults)
        try KakaoLimits.validateSearch(search)
        let chats = try database.chats(limit: KakaoLimits.maximumChatResults)
        chatCache.removeAll(keepingCapacity: true)
        for chat in chats { chatCache[chat.id] = chat }
        let filtered: [Chat]
        if let search, !search.isEmpty {
            filtered = chats.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
        } else {
            filtered = chats
        }
        return Array(filtered.prefix(max(1, limit)))
    }

    public func messages(chatID: ChatID? = nil, since: Date? = nil, limit: Int = 50) throws -> [Message] {
        let limit = try KakaoLimits.validatedResultLimit(limit, maximum: KakaoLimits.maximumMessageResults)
        return try database.messages(chatID: chatID, since: since, limit: limit)
    }

    public func send(_ request: SendRequest) throws -> SendReceipt {
        try KakaoLimits.validateSendBody(request.body)
        return try sender.send(request)
    }

    public func events() -> AsyncThrowingStream<KakaoEvent, Error> {
        let id = UUID()
        let stream = AsyncThrowingStream<KakaoEvent, Error>(bufferingPolicy: .bufferingNewest(1_000)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
        startMonitorIfNeeded()
        return stream
    }

    public func archiveStatus() throws -> ArchiveStatus {
        try state.archiveStatus()
    }

    public func allow(chatID: ChatID) throws {
        guard try database.chat(id: chatID) != nil else { throw KakaoClientError.chatNotFound(chatID) }
        try state.allow(chatID: chatID, startingAfter: database.maxLogID(chatID: chatID))
    }

    public func disallow(chatID: ChatID) throws {
        try state.disallow(chatID: chatID)
    }

    public func allowedChats() throws -> [ChatID] {
        try state.allowedChats().sorted { $0.rawValue < $1.rawValue }
    }

    public func configureWebhook(url: URL?, bearerToken: String?) throws {
        if let url {
            guard WebhookEndpointPolicy.permits(url) else {
                throw KakaoClientError.invalidRequest("Webhook must use HTTPS (HTTP is allowed only on loopback)")
            }
        }
        try state.configureWebhook(url: url?.absoluteString, bearerToken: bearerToken)
    }

    public func processArchiveNow() throws {
        try reconcileArchive()
    }

    private func startMonitorIfNeeded() {
        guard !monitorStarted else { return }
        monitorStarted = true
        monitor.start { [weak self] reason in
            Task { await self?.databaseChanged(reason: reason) }
        }
        Task { [weak self] in await self?.reconcileAfterStartup() }
    }

    private func databaseChanged(reason: DatabaseChangeReason) {
        do {
            while true {
                let messages = try database.messagesSince(logID: eventHighWatermark, limit: 500)
                guard !messages.isEmpty else { break }
                for message in messages {
                    eventHighWatermark = max(eventHighWatermark, message.id)
                    try archive.archive(message)
                    for continuation in continuations.values { continuation.yield(.message(message)) }
                }
                if messages.count < 500 { break }
            }
            if case .reconciliation = reason { try reconcileArchive() }
        } catch {
            // The 60-second backstop remains active. Durable checkpoints make
            // the next event retry metadata that was not committed.
        }
    }

    private func reconcileArchive() throws {
        var checkpoints = try state.archiveCheckpoints()
        guard let minimum = checkpoints.values.min() else { return }
        var cursor = minimum
        while true {
            let messages = try database.messagesSince(logID: cursor, limit: 500)
            guard !messages.isEmpty else { break }
            for message in messages {
                cursor = max(cursor, message.id)
                guard let checkpoint = checkpoints[message.chatId], message.id > checkpoint else { continue }
                if try archive.archive(message) { checkpoints[message.chatId] = message.id }
            }
            if messages.count < 500 { break }
        }
        archive.schedulePendingWork()
        let status = try state.archiveStatus()
        for continuation in continuations.values { continuation.yield(.archiveStatus(status)) }
    }

    private func reconcileAfterStartup() {
        do { try reconcileArchive() }
        catch {
            // Filesystem events and the 60-second reconciliation timer retry.
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            monitor.stop()
            monitorStarted = false
        }
    }
}
