import Foundation
import Testing
@testable import KakaoCore

@Suite("Encrypted state and locking")
struct StateAndLockTests {
    @Test("state survives restart and is not plaintext SQLite")
    func encryptedRestart() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite3").path
        let key = String(repeating: "b", count: 64)
        let requestID = UUID()
        let receipt = SendReceipt(
            requestID: requestID,
            chatID: ChatID(rawValue: 7),
            logID: nil,
            status: .unknown
        )
        do {
            let state = try StateStore(path: path, key: key, archiveRoot: root.path)
            try state.saveSendAttempt(
                destinationKey: "chat:7",
                bodySHA256: "hash",
                body: Data("body".utf8),
                highWatermark: 6,
                receipt: receipt
            )
            state.close()
        }
        let header = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16)
        #expect(String(data: header, encoding: .utf8) != "SQLite format 3\0")
        let reopened = try StateStore(path: path, key: key, archiveRoot: root.path)
        defer { reopened.close() }
        let stored = try reopened.sendAttempt(requestID: requestID)
        #expect(stored?.receipt == receipt)
        #expect(stored?.body == Data("body".utf8))
        #expect(stored?.highWatermark == 6)
    }

    @Test("one confirmed log row is durably owned by one request ID")
    func uniqueConfirmedLogOwner() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite3").path
        let key = String(repeating: "d", count: 64)
        let firstID = UUID()
        let secondID = UUID()
        let body = Data("same body".utf8)

        do {
            let state = try StateStore(path: path, key: key, archiveRoot: root.path)
            for requestID in [firstID, secondID] {
                try state.saveSendAttempt(
                    destinationKey: "chat:7",
                    bodySHA256: "same-hash",
                    body: body,
                    highWatermark: 6,
                    receipt: SendReceipt(
                        requestID: requestID,
                        chatID: ChatID(rawValue: 7),
                        logID: nil,
                        status: .unknown
                    )
                )
            }
            #expect(try state.claimConfirmedSendAttempt(
                destinationKey: "chat:7",
                bodySHA256: "same-hash",
                body: body,
                highWatermark: 6,
                receipt: SendReceipt(
                    requestID: firstID,
                    chatID: ChatID(rawValue: 7),
                    logID: 99,
                    status: .confirmed
                )
            ))
            state.close()
        }

        let reopened = try StateStore(path: path, key: key, archiveRoot: root.path)
        defer { reopened.close() }
        #expect(try !reopened.claimConfirmedSendAttempt(
            destinationKey: "chat:7",
            bodySHA256: "same-hash",
            body: body,
            highWatermark: 6,
            receipt: SendReceipt(
                requestID: secondID,
                chatID: ChatID(rawValue: 7),
                logID: 99,
                status: .confirmed
            )
        ))
        #expect(try reopened.sendAttempt(requestID: firstID)?.receipt.logID == 99)
        #expect(try reopened.sendAttempt(requestID: secondID)?.receipt.status == .unknown)
    }

    @Test("flock excludes another process for the whole transaction")
    func crossProcessLock() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("send.lock").path
        let lock = SendTransactionLock(path: path)
        try lock.lock()
        #expect(try pythonCanLock(path: path) == false)
        lock.unlock()
        #expect(try pythonCanLock(path: path) == true)
    }

    @Test("one lock instance serializes concurrent in-process callers")
    func inProcessLock() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = SendTransactionLock(path: root.appendingPathComponent("send.lock").path)
        let secondAcquired = DispatchSemaphore(value: 0)

        try lock.lock()
        DispatchQueue.global().async {
            guard (try? lock.lock()) != nil else { return }
            secondAcquired.signal()
            lock.unlock()
        }
        #expect(secondAcquired.wait(timeout: .now() + 0.25) == .timedOut)
        lock.unlock()
        #expect(secondAcquired.wait(timeout: .now() + 5) == .success)
    }

    @Test("send lock rejects symbolic-link targets")
    func lockSymlink() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("unrelated")
        #expect(FileManager.default.createFile(atPath: target.path, contents: Data("keep".utf8)))
        let path = root.appendingPathComponent("send.lock")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        let lock = SendTransactionLock(path: path.path)
        #expect(throws: KakaoClientError.self) { try lock.lock() }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }

    @Test("send lock rejects hard-linked targets before changing them")
    func lockHardLink() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("unrelated")
        let path = root.appendingPathComponent("send.lock")
        #expect(FileManager.default.createFile(
            atPath: target.path,
            contents: Data("keep".utf8),
            attributes: [.posixPermissions: 0o644]
        ))
        try FileManager.default.linkItem(at: target, to: path)
        let lock = SendTransactionLock(path: path.path)
        #expect(throws: KakaoClientError.self) { try lock.lock() }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(attributes[.posixPermissions] as? Int == 0o644)
    }

    @Test("legacy import is idempotent and skips pending outbox")
    func migration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old.sqlite")
        try runSQLite(
            path: source.path,
            sql: """
            CREATE TABLE messages(log_id INTEGER PRIMARY KEY, chat_id INTEGER, message_timestamp TEXT, payload_json TEXT);
            CREATE TABLE outbox(id INTEGER PRIMARY KEY, delivered_at REAL);
            INSERT INTO messages VALUES(11, 22, '2026-08-03T00:00:00Z', '{"sender_id":9,"sender":"A","text":"hello","message_type":1,"is_from_me":false}');
            INSERT INTO outbox VALUES(1, NULL);
            """
        )
        let paths = RuntimePaths(
            stateDirectory: root.appendingPathComponent("state", isDirectory: true),
            archiveRoot: root.appendingPathComponent("archive", isDirectory: true)
        )
        try paths.prepare()
        let state = try StateStore(
            path: paths.stateDatabase.path,
            key: String(repeating: "c", count: 64),
            archiveRoot: paths.archiveRoot.path
        )
        defer { state.close() }
        let migrator = LegacyMigrator(state: state, archiveRoot: paths.archiveRoot)
        let first = try migrator.migrate(messagesDatabase: source, mediaDatabase: nil, mediaRoot: nil)
        let second = try migrator.migrate(messagesDatabase: source, mediaDatabase: nil, mediaRoot: nil)
        #expect(first.messagesImported == 1)
        #expect(first.pendingOutboxSkipped == 1)
        #expect(second.messagesImported == 1)
        #expect(try state.archiveStatus().messageCount == 1)
        #expect(try state.archiveStatus().pendingWebhookCount == 0)
        #expect(first.allowedChatsImported == 0)
        #expect(try state.allowedChats().isEmpty)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pythonCanLock(path: String) throws -> Bool {
        let script = """
        import fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sys.exit(0)
        except BlockingIOError:
            sys.exit(1)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func runSQLite(path: String, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw KakaoClientError.state(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }
}
