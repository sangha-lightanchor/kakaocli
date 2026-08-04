import Darwin
import Foundation

public struct ServiceStatus: Codable, Sendable {
    public let running: Bool
    public let processID: Int32
    public let socketPath: String
    public let protocolVersion: Int
}

public struct LocalServiceRequest: Codable, Sendable {
    public let method: String
    public let search: String?
    public let limit: Int?
    public let chatID: ChatID?
    public let since: Date?
    public let sendRequest: SendRequest?

    public init(
        method: String,
        search: String? = nil,
        limit: Int? = nil,
        chatID: ChatID? = nil,
        since: Date? = nil,
        sendRequest: SendRequest? = nil
    ) {
        self.method = method
        self.search = search
        self.limit = limit
        self.chatID = chatID
        self.since = since
        self.sendRequest = sendRequest
    }
}

public struct LocalServiceResponse: Codable, Sendable {
    public let ok: Bool
    public let payload: Data?
    public let error: String?
}

/// A local, same-user service. The lifetime lock is held from before stale
/// socket inspection until the bound socket has been removed.
public final class LocalServiceServer: @unchecked Sendable {
    public static let protocolVersion = 1

    private let socketURL: URL
    private let lifetimeLockURL: URL
    private let maximumConcurrentConnections: Int
    private let stateLock = NSLock()
    private var activeLifecycle: ServiceLifecycle?

    public init(
        socketURL: URL,
        lifetimeLockURL: URL? = nil,
        maximumConcurrentConnections: Int = 8
    ) {
        self.socketURL = socketURL
        self.lifetimeLockURL = lifetimeLockURL
            ?? socketURL.deletingLastPathComponent().appendingPathComponent("service.lock")
        self.maximumConcurrentConnections = max(1, maximumConcurrentConnections)
    }

    /// Runs until SIGINT, SIGTERM, SIGHUP, or an explicit `stop()` call.
    public func run(client: KakaoClient) throws {
        let lifetimeLock = ServiceLifetimeLock(path: lifetimeLockURL.path)
        try lifetimeLock.lock()
        defer { lifetimeLock.unlock() }

        try prepareSocketPath()

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KakaoClientError.state("Could not create the service socket")
        }
        let lifecycle = ServiceLifecycle(descriptor: descriptor)
        setActiveLifecycle(lifecycle)
        defer {
            lifecycle.stop()
            clearActiveLifecycle(lifecycle)
        }

        var address = try unixAddress(path: socketURL.path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw KakaoClientError.state("Could not bind the service socket: \(posixMessage())")
        }
        guard chmod(socketURL.path, 0o600) == 0, Darwin.listen(descriptor, 16) == 0 else {
            throw KakaoClientError.state("Could not secure or listen on the service socket")
        }
        let socketIdentity = try SocketIdentity(path: socketURL.path)
        defer { removeSocketIfUnchanged(socketIdentity) }

        let signals = ServiceSignalHandlers { [weak self] in self?.stop() }
        defer { signals.cancel() }

        let eventTask = Task.detached(priority: .utility) {
            let stream = await client.events()
            do {
                for try await _ in stream {
                    if Task.isCancelled { break }
                }
            } catch {
                // Socket requests remain available. Archive health is exposed
                // separately and a new service process will reconcile on start.
            }
        }
        defer { eventTask.cancel() }

        let slots = DispatchSemaphore(value: maximumConcurrentConnections)
        let handlers = DispatchGroup()
        defer { handlers.wait() }

        while !lifecycle.isStopping {
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                if lifecycle.isStopping || errno == EBADF || errno == EINVAL { break }
                throw KakaoClientError.state("Service accept failed: \(posixMessage())")
            }

            slots.wait()
            handlers.enter()
            Task.detached(priority: .utility) { [self] in
                defer {
                    Darwin.close(connection)
                    slots.signal()
                    handlers.leave()
                }
                await serve(connection: connection, client: client)
            }
        }
    }

    public func stop() {
        stateLock.withLock { activeLifecycle }?.stop()
    }

    private func serve(connection: Int32, client: KakaoClient) async {
        do {
            try requireSameUserPeer(connection)
            try configureSocket(connection, receiveTimeout: 5, sendTimeout: 10)
            let requestData = try LocalServiceIO.readFrame(
                from: connection,
                maximumBytes: KakaoLimits.maximumServiceRequestBytes
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let request = try decoder.decode(LocalServiceRequest.self, from: requestData)
            let response = try await handle(request, client: client)
            try LocalServiceIO.writeFrame(
                response,
                to: connection,
                maximumBytes: KakaoLimits.maximumServiceResponseBytes
            )
        } catch {
            let response = LocalServiceResponse(
                ok: false,
                payload: nil,
                error: String(describing: error)
            )
            try? LocalServiceIO.writeFrame(
                response,
                to: connection,
                maximumBytes: KakaoLimits.maximumServiceResponseBytes
            )
        }
    }

    private func handle(_ request: LocalServiceRequest, client: KakaoClient) async throws -> LocalServiceResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload: Data
        switch request.method {
        case "status":
            payload = try encoder.encode(ServiceStatus(
                running: true,
                processID: getpid(),
                socketPath: socketURL.path,
                protocolVersion: Self.protocolVersion
            ))
        case "chats":
            let limit = try KakaoLimits.validatedResultLimit(
                request.limit ?? KakaoLimits.defaultResultLimit,
                maximum: KakaoLimits.maximumChatResults
            )
            try KakaoLimits.validateSearch(request.search)
            payload = try encoder.encode(try await client.listChats(search: request.search, limit: limit))
        case "messages":
            let limit = try KakaoLimits.validatedResultLimit(
                request.limit ?? KakaoLimits.defaultResultLimit,
                maximum: KakaoLimits.maximumMessageResults
            )
            payload = try encoder.encode(
                try await client.messages(chatID: request.chatID, since: request.since, limit: limit)
            )
        case "send":
            guard let sendRequest = request.sendRequest else {
                throw KakaoClientError.invalidRequest("Service send request is missing its payload")
            }
            try KakaoLimits.validateSendBody(sendRequest.body)
            payload = try encoder.encode(try await client.send(sendRequest))
        case "archive_status":
            payload = try encoder.encode(try await client.archiveStatus())
        default:
            throw KakaoClientError.invalidRequest("Unknown service method")
        }
        guard payload.count <= KakaoLimits.maximumServicePayloadBytes else {
            throw KakaoClientError.invalidRequest("Service response payload exceeded the configured limit")
        }
        return LocalServiceResponse(ok: true, payload: payload, error: nil)
    }

    private func prepareSocketPath() throws {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw KakaoClientError.state("Could not inspect the service socket path")
        }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
            throw KakaoClientError.state("Refusing to replace a socket path not owned by this user")
        }
        if LocalServiceConnection(socketURL: socketURL).canConnect(timeout: 0.25) {
            throw KakaoClientError.state("The kakaocli service is already running")
        }
        guard unlink(socketURL.path) == 0 else {
            throw KakaoClientError.state("Could not remove the stale service socket")
        }
    }

    private func removeSocketIfUnchanged(_ identity: SocketIdentity) {
        guard (try? SocketIdentity(path: socketURL.path)) == identity else { return }
        _ = unlink(socketURL.path)
    }

    private func setActiveLifecycle(_ lifecycle: ServiceLifecycle) {
        stateLock.withLock { activeLifecycle = lifecycle }
    }

    private func clearActiveLifecycle(_ lifecycle: ServiceLifecycle) {
        stateLock.withLock {
            if activeLifecycle === lifecycle { activeLifecycle = nil }
        }
    }
}

public final class LocalServiceConnection: @unchecked Sendable {
    private let socketURL: URL
    private let requestTimeout: TimeInterval

    public init(socketURL: URL, requestTimeout: TimeInterval = 30) {
        self.socketURL = socketURL
        self.requestTimeout = max(0.1, requestTimeout)
    }

    public var isAvailable: Bool {
        (try? callRaw(LocalServiceRequest(method: "status"), timeout: 0.75))?.ok == true
    }

    public func call<Response: Decodable>(_ request: LocalServiceRequest, as type: Response.Type) throws -> Response {
        let response = try callRaw(request, timeout: requestTimeout)
        guard response.ok, let payload = response.payload else {
            throw KakaoClientError.state(response.error ?? "Service request failed")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: payload)
    }

    func canConnect(timeout: TimeInterval) -> Bool {
        guard let descriptor = try? connectedSocket(timeout: timeout) else { return false }
        Darwin.close(descriptor)
        return true
    }

    private func callRaw(_ request: LocalServiceRequest, timeout: TimeInterval) throws -> LocalServiceResponse {
        let descriptor = try connectedSocket(timeout: min(timeout, 2))
        defer { Darwin.close(descriptor) }
        try configureSocket(descriptor, receiveTimeout: timeout, sendTimeout: min(timeout, 5))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try LocalServiceIO.writeFrame(
            request,
            to: descriptor,
            maximumBytes: KakaoLimits.maximumServiceRequestBytes
        )
        let responseData = try LocalServiceIO.readFrame(
            from: descriptor,
            maximumBytes: KakaoLimits.maximumServiceResponseBytes
        )
        return try JSONDecoder().decode(LocalServiceResponse.self, from: responseData)
    }

    private func connectedSocket(timeout: TimeInterval) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KakaoClientError.state("Could not create a client socket")
        }
        do {
            try setNoSigPipe(descriptor)
            let flags = fcntl(descriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw KakaoClientError.state("Could not configure a client socket")
            }
            defer { _ = fcntl(descriptor, F_SETFL, flags) }

            var address = try unixAddress(path: socketURL.path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else {
                    throw KakaoClientError.state("kakaocli service is not running")
                }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let milliseconds = Int32(min(max(timeout * 1_000, 1), Double(Int32.max)))
                guard Darwin.poll(&pollDescriptor, 1, milliseconds) > 0 else {
                    throw KakaoClientError.state("Timed out connecting to the kakaocli service")
                }
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                      socketError == 0 else {
                    throw KakaoClientError.state("kakaocli service is not running")
                }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}

enum LocalServiceIO {
    static func readFrame(from descriptor: Int32, maximumBytes: Int) throws -> Data {
        let header = try readExactly(4, from: descriptor)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(maximumBytes) else {
            throw KakaoClientError.invalidRequest("Service frame exceeded the configured limit")
        }
        return try readExactly(Int(length), from: descriptor)
    }

    static func writeFrame<Value: Encodable>(
        _ value: Value,
        to descriptor: Int32,
        maximumBytes: Int
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard payload.count <= maximumBytes, payload.count <= Int(UInt32.max) else {
            throw KakaoClientError.invalidRequest("Service frame exceeded the configured limit")
        }
        let count = UInt32(payload.count)
        let header = Data([
            UInt8((count >> 24) & 0xff), UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff), UInt8(count & 0xff),
        ])
        try writeAll(header, to: descriptor)
        try writeAll(payload, to: descriptor)
    }

    private static func readExactly(_ byteCount: Int, from descriptor: Int32) throws -> Data {
        guard byteCount > 0 else { return Data() }
        var output = Data(count: byteCount)
        try output.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < byteCount {
                let result = Darwin.read(descriptor, base.advanced(by: offset), byteCount - offset)
                if result > 0 {
                    offset += result
                    continue
                }
                if result == 0 { throw KakaoClientError.state("Service socket closed mid-frame") }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw KakaoClientError.state("Service socket read timed out")
                }
                throw KakaoClientError.state("Service socket read failed: \(posixMessage())")
            }
        }
        return output
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR { continue }
                if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    throw KakaoClientError.state("Service socket write timed out")
                }
                throw KakaoClientError.state("Service socket write failed: \(posixMessage())")
            }
        }
    }
}

final class ServiceLifetimeLock: @unchecked Sendable {
    private let path: String
    private var descriptor: Int32 = -1

    init(path: String) { self.path = path }
    deinit { unlock() }

    func lock() throws {
        guard descriptor == -1 else { return }
        let opened = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard opened >= 0 else {
            throw KakaoClientError.state("Could not open the service lifetime lock")
        }
        var info = stat()
        guard fstat(opened, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG,
              fchmod(opened, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(opened)
            throw KakaoClientError.state("The service lifetime lock is not a secure regular file")
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(opened)
            throw KakaoClientError.state("The kakaocli service is already running")
        }
        descriptor = opened
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}

private final class ServiceLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var stopping = false

    init(descriptor: Int32) { self.descriptor = descriptor }

    var isStopping: Bool { lock.withLock { stopping } }

    func stop() {
        let value: Int32? = lock.withLock {
            guard !stopping else { return nil }
            stopping = true
            let value = descriptor
            descriptor = -1
            return value
        }
        if let value, value >= 0 { Darwin.close(value) }
    }
}

private final class ServiceSignalHandlers: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]

    init(stop: @escaping @Sendable () -> Void) {
        let signals = [SIGINT, SIGTERM, SIGHUP]
        for signalNumber in signals { Darwin.signal(signalNumber, SIG_IGN) }
        sources = signals.map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .utility))
            source.setEventHandler(handler: stop)
            source.resume()
            return source
        }
    }

    func cancel() {
        for source in sources { source.cancel() }
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] { Darwin.signal(signalNumber, SIG_DFL) }
    }

    deinit { cancel() }
}

private struct SocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else {
            throw KakaoClientError.state("The service socket identity could not be verified")
        }
        device = info.st_dev
        inode = info.st_ino
    }
}

private func requireSameUserPeer(_ descriptor: Int32) throws {
    var effectiveUserID: uid_t = 0
    var effectiveGroupID: gid_t = 0
    guard getpeereid(descriptor, &effectiveUserID, &effectiveGroupID) == 0,
          effectiveUserID == geteuid() else {
        throw KakaoClientError.state("Rejected a service connection from another user")
    }
}

private func configureSocket(
    _ descriptor: Int32,
    receiveTimeout: TimeInterval,
    sendTimeout: TimeInterval
) throws {
    try setNoSigPipe(descriptor)
    var receive = socketTimeval(receiveTimeout)
    var send = socketTimeval(sendTimeout)
    guard setsockopt(
        descriptor, SOL_SOCKET, SO_RCVTIMEO,
        &receive, socklen_t(MemoryLayout<timeval>.size)
    ) == 0,
    setsockopt(
        descriptor, SOL_SOCKET, SO_SNDTIMEO,
        &send, socklen_t(MemoryLayout<timeval>.size)
    ) == 0 else {
        throw KakaoClientError.state("Could not configure service socket deadlines")
    }
}

private func setNoSigPipe(_ descriptor: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE,
        &enabled, socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        throw KakaoClientError.state("Could not disable SIGPIPE on a service socket")
    }
}

private func socketTimeval(_ interval: TimeInterval) -> timeval {
    let bounded = max(0.001, interval)
    let seconds = floor(bounded)
    return timeval(
        tv_sec: Int(seconds),
        tv_usec: Int32((bounded - seconds) * 1_000_000)
    )
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    #if os(macOS)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let bytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else {
        throw KakaoClientError.invalidRequest("Unix socket path is too long")
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            for index in 0..<bytes.count { destination[index] = bytes[index] }
        }
    }
    return address
}

private func posixMessage() -> String {
    String(cString: strerror(errno))
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
