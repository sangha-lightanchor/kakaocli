import Darwin
import Foundation
import Testing
@testable import KakaoCore

@Suite("Service, watcher, and runtime hardening")
struct ServiceAndRuntimeTests {
    @Test("service frames are length-delimited and bounded")
    func framedIO() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer {
            Darwin.close(sockets[0])
            Darwin.close(sockets[1])
        }

        let request = LocalServiceRequest(method: "messages", limit: 25)
        try LocalServiceIO.writeFrame(request, to: sockets[0], maximumBytes: 1_024)
        let data = try LocalServiceIO.readFrame(from: sockets[1], maximumBytes: 1_024)
        let decoded = try JSONDecoder().decode(LocalServiceRequest.self, from: data)
        #expect(decoded.method == "messages")
        #expect(decoded.limit == 25)

        let warmup = LocalServiceRequest(method: "warmup_v2", destination: .selfChat)
        let warmupData = try JSONEncoder().encode(warmup)
        let decodedWarmup = try JSONDecoder().decode(LocalServiceRequest.self, from: warmupData)
        #expect(decodedWarmup.method == "warmup_v2")
        #expect(decodedWarmup.destination == .selfChat)

        #expect(throws: KakaoClientError.self) {
            try LocalServiceIO.writeFrame(request, to: sockets[0], maximumBytes: 1)
        }
    }

    @Test("service lifetime lock excludes a second server")
    func lifetimeLock() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("service.lock").path
        let first = ServiceLifetimeLock(path: path)
        let second = ServiceLifetimeLock(path: path)
        try first.lock()
        #expect(throws: KakaoClientError.self) { try second.lock() }
        first.unlock()
        try second.lock()
        second.unlock()
    }

    @Test("service accepts same-user framed status and cleans its socket on stop")
    func serviceLifecycle() throws {
        let root = URL(fileURLWithPath: "/tmp/kc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RuntimePaths(
            stateDirectory: root.appendingPathComponent("state", isDirectory: true),
            archiveRoot: root.appendingPathComponent("archive", isDirectory: true)
        )
        try paths.prepare()
        let databaseURL = root.appendingPathComponent("source.sqlite3")
        try createServiceDatabase(at: databaseURL)
        let database = DatabaseReader(databasePath: databaseURL.path)
        try database.open()
        defer { database.close() }
        let state = try StateStore(
            path: paths.stateDatabase.path,
            key: String(repeating: "d", count: 64),
            archiveRoot: paths.archiveRoot.path
        )
        defer { state.close() }
        let sender = SafeSendCoordinator(
            database: database,
            state: state,
            ui: NoopServiceUI(),
            transactionLock: SendTransactionLock(path: paths.lock.path),
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
        let client = try KakaoClient(
            database: database,
            state: state,
            sender: sender,
            archive: ArchiveCoordinator(
                state: state,
                media: MediaArchiver(state: state, root: paths.archiveRoot),
                webhook: GenericWebhook(state: state)
            ),
            monitor: DatabaseChangeMonitor(databasePath: databaseURL.path)
        )
        let server = LocalServiceServer(
            socketURL: paths.socket,
            lifetimeLockURL: paths.serviceLock,
            maximumConcurrentConnections: 2
        )
        let completion = ServiceCompletion()
        Thread.detachNewThread {
            do { try server.run(client: client); completion.finish(error: nil) }
            catch { completion.finish(error: String(describing: error)) }
        }

        let connection = LocalServiceConnection(socketURL: paths.socket, requestTimeout: 2)
        #expect(waitUntil(timeout: 3) { connection.isAvailable })
        let status = try connection.call(LocalServiceRequest(method: "status"), as: ServiceStatus.self)
        #expect(status.running)
        #expect(status.protocolVersion == LocalServiceServer.protocolVersion)
        server.stop()
        #expect(waitUntil(timeout: 3) { completion.finished })
        #expect(completion.error == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.socket.path))
    }

    @Test("watcher attaches to a new WAL and rearms after replacement")
    func watcherRearms() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("database.sqlite3")
        let wal = URL(fileURLWithPath: database.path + "-wal")
        try Data("db".utf8).write(to: database)

        let count = LockedCounter()
        let monitor = DatabaseChangeMonitor(
            databasePath: database.path,
            debounce: 0.02,
            reconciliation: 30
        )
        monitor.start { reason in
            if case .filesystem = reason { count.increment() }
        }
        defer { monitor.stop() }

        let beforeWAL = count.value
        try Data("wal".utf8).write(to: wal)
        #expect(waitUntil { count.value > beforeWAL })

        Thread.sleep(forTimeInterval: 0.1)
        let afterCreation = count.value
        let handle = try FileHandle(forWritingTo: wal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("+".utf8))
        try handle.close()
        #expect(waitUntil { count.value > afterCreation })

        try FileManager.default.removeItem(at: database)
        try Data("replacement".utf8).write(to: database)
        #expect(waitUntil { count.value > afterCreation + 1 })

        Thread.sleep(forTimeInterval: 0.1)
        let afterReplacement = count.value
        let replacementHandle = try FileHandle(forWritingTo: database)
        try replacementHandle.seekToEnd()
        try replacementHandle.write(contentsOf: Data("+".utf8))
        try replacementHandle.close()
        #expect(waitUntil { count.value > afterReplacement })
    }

    @Test("runtime preparation rejects a symlinked managed directory")
    func runtimeSymlink() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)
        let paths = RuntimePaths(
            stateDirectory: state,
            archiveRoot: root.appendingPathComponent("archive", isDirectory: true)
        )
        #expect(throws: KakaoClientError.self) { try paths.prepare() }
    }

    @Test("database identity cache stores no key and is user-only")
    func databaseIdentityCache() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state/source-database.json")
        let cache = DatabaseIdentityCache(url: url)
        let identity = DatabaseIdentity(path: "/tmp/example.sqlite3", userID: 123)
        try cache.store(identity)
        #expect(cache.load() == identity)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.localizedCaseInsensitiveContains("key"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("database path overrides support plaintext and one-shot stdin keys")
    func databasePathOverrides() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("source.sqlite3")
        try createServiceDatabase(at: database)
        let cache = root.appendingPathComponent("identity.json")

        let plaintext = try DatabaseLocator.resolve(
            databasePath: database.path,
            cacheURL: cache
        )
        #expect(plaintext.path == database.path)
        #expect(plaintext.key == nil)

        let oneShot = try DatabaseLocator.resolve(
            databasePath: database.path,
            key: "one-shot-secret",
            cacheURL: cache
        )
        #expect(oneShot.key == "one-shot-secret")
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("state key is a durable user-only 32-byte hex secret")
    func stateKeyFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let url = stateDirectory.appendingPathComponent("state.key")

        let first = try StateKeyStore.loadOrCreate(at: url)
        let second = try StateKeyStore.loadOrCreate(at: url)
        #expect(first == second)
        #expect(first.utf8.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit })
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.size] as? NSNumber)?.intValue == 64)
    }

    @Test("state key rejects insecure files without replacing them")
    func insecureStateKeyFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let url = stateDirectory.appendingPathComponent("state.key")
        let invalid = String(repeating: "g", count: 64)
        try Data(invalid.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        #expect(throws: KakaoClientError.self) {
            try StateKeyStore.loadOrCreate(at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == invalid)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: KakaoClientError.self) {
            try StateKeyStore.loadOrCreate(at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == invalid)
    }

    @Test("state key rejects symlinks")
    func symlinkedStateKeyFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let target = root.appendingPathComponent("target")
        try Data(String(repeating: "a", count: 64).utf8).write(to: target)
        let url = stateDirectory.appendingPathComponent("state.key")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        #expect(throws: KakaoClientError.self) {
            try StateKeyStore.loadOrCreate(at: url)
        }
    }

    @Test("concurrent state-key creation uses one atomic winner")
    func stateKeyCreationRace() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let url = stateDirectory.appendingPathComponent("state.key")
        let results = StateKeyResults()

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { results.append(try StateKeyStore.loadOrCreate(at: url)) }
            catch { results.recordFailure() }
        }

        #expect(results.failureCount == 0)
        #expect(results.values.count == 16)
        #expect(Set(results.values).count == 1)
    }

    @Test("shared limits reject hostile local input")
    func limits() throws {
        #expect(try KakaoLimits.validatedResultLimit(1, maximum: 500) == 1)
        #expect(throws: KakaoClientError.self) {
            try KakaoLimits.validatedResultLimit(0, maximum: 500)
        }
        #expect(throws: KakaoClientError.self) {
            try KakaoLimits.validatedResultLimit(501, maximum: 500)
        }
        #expect(KakaoLimits.date(sinceDuration: "1h") != nil)
        #expect(KakaoLimits.date(sinceDuration: "-1h") == nil)
        #expect(KakaoLimits.date(sinceDuration: "nanh") == nil)
        #expect(throws: KakaoClientError.self) {
            try KakaoLimits.validateSendBody(String(repeating: "x", count: KakaoLimits.maximumSendBodyBytes + 1))
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class StateKeyResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    private var storedFailureCount = 0

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFailureCount
    }

    func append(_ value: String) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }

    func recordFailure() {
        lock.lock()
        storedFailureCount += 1
        lock.unlock()
    }
}

private final class NoopServiceUI: KakaoSendUI, @unchecked Sendable {
    func submit(chat: Chat, body: String) throws {
        throw SendUIError.preconditionFailed("not used by the service status test")
    }
}

private final class ServiceCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFinished = false
    private var storedError: String?

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedFinished
    }

    var error: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func finish(error: String?) {
        lock.lock()
        storedError = error
        storedFinished = true
        lock.unlock()
    }
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func createServiceDatabase(at url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
        url.path,
        "CREATE TABLE NTChatMessage(logId INTEGER PRIMARY KEY, chatId INTEGER, authorId INTEGER, message BLOB, type INTEGER, sentAt INTEGER, attachment TEXT); CREATE TABLE NTChatContext(userId INTEGER); INSERT INTO NTChatContext VALUES(1);",
    ]
    let errors = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw KakaoClientError.state(
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

private func waitUntil(
    timeout: TimeInterval = 2,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
