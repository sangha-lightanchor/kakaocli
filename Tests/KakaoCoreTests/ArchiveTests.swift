import CryptoKit
import Foundation
import Testing
@testable import KakaoCore

@Suite("Allowlisted archive")
struct ArchiveTests {
    @Test("normalizes links, video metadata, and multi-photo records")
    func normalization() throws {
        let video = message(
            id: 1,
            type: .video,
            text: "reference https://example.com/page",
            attachment: #"{"url":"https://cdn.example.com/a.mp4","s":4,"d":1234,"w":1920,"h":1080,"cs":"A9993E364706816ABA3E25717850C26C9CD0D89D"}"#
        )
        let normalized = AttachmentNormalizer.normalize(message: video)
        #expect(normalized.contains { $0.kind == .video && $0.expectedBytes == 4 && $0.width == 1920 })
        #expect(normalized.contains { $0.kind == .link && $0.remoteURL?.host == "example.com" })

        let photos = message(
            id: 2,
            type: .photo,
            attachment: #"[{"url":"https://cdn.example.com/1.jpg"},{"url":"https://cdn.example.com/2.jpg"}]"#
        )
        let photoItems = AttachmentNormalizer.normalize(message: photos)
        #expect(photoItems.count == 2)
        #expect(photoItems.allSatisfy { $0.kind == .multiPhoto })
    }

    @Test("archives only allowlisted chat IDs")
    func allowlist() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let attachments = AttachmentNormalizer.normalize(message: fixture.message)
        #expect(try fixture.state.archive(message: fixture.message, attachments: attachments) == false)
        try fixture.state.allow(chatID: fixture.message.chatId)
        #expect(try fixture.state.archive(message: fixture.message, attachments: attachments) == true)
        #expect(try fixture.state.archiveStatus().messageCount == 1)
    }

    @Test("verifies checksums and deduplicates content-addressed objects")
    func checksumAndDeduplication() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId)
        let data = Data("abc".utf8)
        let sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        for id in [10, 11] {
            let item = message(
                id: Int64(id),
                type: .video,
                attachment: "{\"url\":\"https://cdn.example.com/\(id)\",\"s\":3,\"cs\":\"\(sha1)\"}"
            )
            try fixture.state.archive(message: item, attachments: AttachmentNormalizer.normalize(message: item))
        }
        let archiver = MediaArchiver(
            state: fixture.state,
            root: fixture.paths.archiveRoot,
            fetcher: MockFetcher(result: .success(MediaFetchResponse(data: data, statusCode: 200, finalURL: URL(string: "https://cdn.example.com/final")!))),
            disk: MockDisk(bytes: Int64.max)
        )
        try archiver.processPending(limit: 10)
        let status = try fixture.state.archiveStatus()
        #expect(status.objectCount == 1)
        #expect(status.pendingDownloadCount == 0)
    }

    @Test("partial downloads and checksum failures remain terminal metadata")
    func verificationFailures() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId)
        let item = message(
            id: 20,
            type: .video,
            attachment: #"{"url":"https://cdn.example.com/video","s":99,"cs":"bad"}"#
        )
        try fixture.state.archive(message: item, attachments: AttachmentNormalizer.normalize(message: item))
        let archiver = MediaArchiver(
            state: fixture.state,
            root: fixture.paths.archiveRoot,
            fetcher: MockFetcher(result: .success(MediaFetchResponse(data: Data("short".utf8), statusCode: 200, finalURL: URL(string: "https://cdn.example.com/video")!))),
            disk: MockDisk(bytes: Int64.max)
        )
        try archiver.processPending()
        #expect(try fixture.state.archiveStatus().pendingDownloadCount == 0)
        #expect(try fixture.state.archiveStatus().failedDownloadCount == 1)
        #expect(try fixture.state.attachmentDelivery(logID: item.id).first?.status == "verification_failed")
    }

    @Test("critical disk pressure pauses downloads without losing metadata")
    func lowDisk() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId)
        try fixture.state.archive(
            message: fixture.message,
            attachments: AttachmentNormalizer.normalize(message: fixture.message)
        )
        let archiver = MediaArchiver(
            state: fixture.state,
            root: fixture.paths.archiveRoot,
            fetcher: MockFetcher(result: .failure(MediaArchiveError.downloadFailed("must not run"))),
            disk: MockDisk(bytes: 1),
            criticalFreeBytes: 2
        )
        try archiver.processPending()
        let status = try fixture.state.archiveStatus()
        #expect(status.messageCount == 1)
        #expect(status.attachmentCount == 1)
        #expect(status.pausedLowDiskCount == 1)
    }

    @Test("expired URLs and insecure redirects retain metadata without retry output")
    func expiredAndRedirect() throws {
        for error in [MediaArchiveError.expired, MediaArchiveError.insecureRedirect] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.state.allow(chatID: fixture.message.chatId)
            try fixture.state.archive(
                message: fixture.message,
                attachments: AttachmentNormalizer.normalize(message: fixture.message)
            )
            let archiver = MediaArchiver(
                state: fixture.state,
                root: fixture.paths.archiveRoot,
                fetcher: MockFetcher(result: .failure(error)),
                disk: MockDisk(bytes: Int64.max)
            )
            try archiver.processPending()
            let status = try fixture.state.archiveStatus()
            #expect(status.messageCount == 1)
            #expect(status.attachmentCount == 1)
            if error == .expired { #expect(status.expiredAttachmentCount == 1) }
            else {
                #expect(status.failedDownloadCount == 1)
                #expect(try fixture.state.attachmentDelivery(logID: fixture.message.id).first?.status == "verification_failed")
            }
        }
    }

    @Test("ordinary links remain metadata-only and are never fetched")
    func linksAreMetadataOnly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId)
        let item = message(id: 30, type: .text, text: "tracking https://attacker.example/beacon", attachment: nil)
        try fixture.state.archive(message: item, attachments: AttachmentNormalizer.normalize(message: item))
        let fetcher = CountingFetcher()
        let archiver = MediaArchiver(
            state: fixture.state,
            root: fixture.paths.archiveRoot,
            fetcher: fetcher,
            disk: MockDisk(bytes: Int64.max)
        )
        try archiver.processPending()
        #expect(fetcher.count == 0)
        #expect(try fixture.state.attachmentDelivery(logID: item.id).first?.status == "metadata_only")
    }

    @Test("media URL policy rejects local and unapproved endpoints")
    func mediaURLPolicy() {
        let policy = MediaURLPolicy(approvedDomainSuffixes: ["kakaocdn.net"], resolveAddresses: false)
        #expect(policy.permits(URL(string: "https://cdn.kakaocdn.net/video")!))
        #expect(!policy.permits(URL(string: "https://kakaocdn.net.attacker.example/video")!))
        #expect(!policy.permits(URL(string: "https://localhost/video")!))
        #expect(!policy.permits(URL(string: "http://cdn.kakaocdn.net/video")!))
        #expect(!policy.permits(URL(string: "https://user:secret@cdn.kakaocdn.net/video")!))
    }

    @Test("local files must be regular owned files below an approved root")
    func localPathPolicy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId)
        let approved = fixture.root.appendingPathComponent("approved", isDirectory: true)
        try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
        let source = approved.appendingPathComponent("video.bin")
        try Data("abc".utf8).write(to: source)
        let outside = fixture.root.appendingPathComponent("outside.bin")
        try Data("secret".utf8).write(to: outside)
        let symlink = approved.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        let allowedItem = message(id: 31, type: .video, attachment: "{\"path\":\"\(source.path)\",\"s\":3}")
        let outsideItem = message(id: 32, type: .video, attachment: "{\"path\":\"\(outside.path)\"}")
        let symlinkItem = message(id: 33, type: .video, attachment: "{\"path\":\"\(symlink.path)\"}")
        for item in [allowedItem, outsideItem, symlinkItem] {
            try fixture.state.archive(message: item, attachments: AttachmentNormalizer.normalize(message: item))
        }
        let archiver = MediaArchiver(
            state: fixture.state,
            root: fixture.paths.archiveRoot,
            fetcher: CountingFetcher(),
            disk: MockDisk(bytes: Int64.max),
            allowedLocalRoots: [approved]
        )
        try archiver.processPending(limit: 10)
        #expect(try fixture.state.attachmentDelivery(logID: 31).first?.status == "complete")
        #expect(try fixture.state.attachmentDelivery(logID: 32).first?.status == "verification_failed")
        #expect(try fixture.state.attachmentDelivery(logID: 33).first?.status == "verification_failed")
    }

    @Test("oversized responses are rejected before CAS registration")
    func boundedResponse() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId)
        try fixture.state.archive(message: fixture.message, attachments: AttachmentNormalizer.normalize(message: fixture.message))
        let archiver = MediaArchiver(
            state: fixture.state,
            root: fixture.paths.archiveRoot,
            fetcher: MockFetcher(result: .success(MediaFetchResponse(
                data: Data(repeating: 1, count: 5),
                statusCode: 200,
                finalURL: URL(string: "https://cdn.example.com/video")!
            ))),
            disk: MockDisk(bytes: Int64.max),
            maximumObjectBytes: 4
        )
        try archiver.processPending()
        #expect(try fixture.state.archiveStatus().objectCount == 0)
        #expect(try fixture.state.attachmentDelivery(logID: fixture.message.id).first?.status == "verification_failed")
    }

    @Test("attachment rows are leased to prevent duplicate workers")
    func attachmentLease() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId)
        try fixture.state.archive(message: fixture.message, attachments: AttachmentNormalizer.normalize(message: fixture.message))
        #expect(try fixture.state.pendingAttachments(limit: 1).count == 1)
        #expect(try fixture.state.pendingAttachments(limit: 1).isEmpty)
    }

    @Test("archive checkpoints advance transactionally and survive restart")
    func durableCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RuntimePaths(
            stateDirectory: root.appendingPathComponent("state", isDirectory: true),
            archiveRoot: root.appendingPathComponent("archive", isDirectory: true)
        )
        try paths.prepare()
        let key = String(repeating: "d", count: 64)
        do {
            let state = try StateStore(path: paths.stateDatabase.path, key: key, archiveRoot: paths.archiveRoot.path)
            try state.allow(chatID: ChatID(rawValue: 44), startingAfter: 100)
            let item = message(id: 101, type: .text, text: "checkpoint", attachment: nil)
            #expect(try state.archive(message: item, attachments: []) == true)
            #expect(try state.archiveCheckpoints()[ChatID(rawValue: 44)] == 100)
            #expect(try GenericWebhook(state: state, transport: MockWebhook()).enqueue(message: item, attachments: []) == false)
            #expect(try state.archiveCheckpoints()[ChatID(rawValue: 44)] == 101)
            state.close()
        }
        let reopened = try StateStore(path: paths.stateDatabase.path, key: key, archiveRoot: paths.archiveRoot.path)
        defer { reopened.close() }
        #expect(try reopened.archiveCheckpoints()[ChatID(rawValue: 44)] == 101)
    }

    @Test("enabled webhook outbox and checkpoint commit idempotently together")
    func atomicWebhookCheckpoint() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId, startingAfter: 0)
        try fixture.state.configureWebhook(url: "https://hooks.example.com/events", bearerToken: "fresh")
        let item = message(id: 102, type: .text, text: "atomic", attachment: nil)
        try fixture.state.archive(message: item, attachments: [])
        let webhook = GenericWebhook(state: fixture.state, transport: MockWebhook())
        #expect(try webhook.enqueue(message: item, attachments: []) == true)
        #expect(try fixture.state.archiveCheckpoints()[item.chatId] == 102)
        #expect(try fixture.state.archiveStatus().pendingWebhookCount == 1)

        // Replay after a crash is harmless: metadata and event IDs are stable.
        try fixture.state.archive(message: item, attachments: [])
        #expect(try webhook.enqueue(message: item, attachments: []) == true)
        #expect(try fixture.state.archiveCheckpoints()[item.chatId] == 102)
        #expect(try fixture.state.archiveStatus().pendingWebhookCount == 1)
    }

    @Test("failed webhook enqueue leaves the archive checkpoint replayable")
    func webhookFailureDoesNotAdvanceCheckpoint() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId, startingAfter: 0)
        try fixture.state.configureWebhook(url: "https://hooks.example.com/events", bearerToken: nil)
        let item = message(id: 103, type: .text, text: "retry-me", attachment: nil)
        try fixture.state.archive(message: item, attachments: [])
        #expect(throws: KakaoClientError.self) {
            try fixture.state.completeArchiveIngestion(
                chatID: item.chatId,
                logID: item.id,
                webhookEventID: "",
                webhookPayload: Data()
            )
        }
        #expect(try fixture.state.archiveCheckpoints()[item.chatId] == 0)
        #expect(try fixture.state.archiveStatus().pendingWebhookCount == 0)

        // The same stored metadata is replayed without duplication once the
        // outbox can accept the deterministic event.
        let webhook = GenericWebhook(state: fixture.state, transport: MockWebhook())
        #expect(try webhook.enqueue(message: item, attachments: []) == true)
        #expect(try fixture.state.archiveCheckpoints()[item.chatId] == 103)
        #expect(try fixture.state.archiveStatus().pendingWebhookCount == 1)
    }

    @Test("webhook reconfiguration clears stale credentials atomically")
    func atomicWebhookConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.configureWebhook(url: "https://old.example/events", bearerToken: "obsolete")
        try fixture.state.configureWebhook(url: "https://new.example/events", bearerToken: nil)
        #expect(try fixture.state.configuration(key: GenericWebhook.URLKey) == "https://new.example/events")
        #expect(try fixture.state.configuration(key: GenericWebhook.bearerKey) == nil)
        #expect(try fixture.state.webhookConfiguration()?.url == "https://new.example/events")
        #expect(try fixture.state.webhookConfiguration()?.bearerToken == nil)
        try fixture.state.configureWebhook(url: nil, bearerToken: "must-not-survive")
        #expect(try fixture.state.configuration(key: GenericWebhook.URLKey) == nil)
        #expect(try fixture.state.configuration(key: GenericWebhook.bearerKey) == nil)
        #expect(try fixture.state.webhookConfiguration()?.url == nil)
    }

    @Test("corrupt existing CAS objects are quarantined and rebuilt")
    func casCorruptionRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId)
        let data = Data("abc".utf8)
        let fetcher = MockFetcher(result: .success(MediaFetchResponse(
            data: data,
            statusCode: 200,
            finalURL: URL(string: "https://cdn.example.com/video")!
        )))
        let archiver = MediaArchiver(
            state: fixture.state,
            root: fixture.paths.archiveRoot,
            fetcher: fetcher,
            disk: MockDisk(bytes: Int64.max)
        )
        try fixture.state.archive(message: fixture.message, attachments: AttachmentNormalizer.normalize(message: fixture.message))
        try archiver.processPending()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = fixture.paths.archiveRoot.appendingPathComponent("objects/\(hash.prefix(2))")
        let object = directory.appendingPathComponent(hash)
        try Data("bad".utf8).write(to: object)

        let second = message(id: 41, type: .video, attachment: #"{"url":"https://cdn.example.com/again","s":3}"#)
        try fixture.state.archive(message: second, attachments: AttachmentNormalizer.normalize(message: second))
        try archiver.processPending()
        #expect(try Data(contentsOf: object) == data)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.contains(".corrupt.") })
    }

    @Test("webhook payload excludes signed URLs and local paths")
    func webhookPrivacy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId)
        try fixture.state.setConfiguration(key: GenericWebhook.URLKey, value: "https://hooks.example.com/events")
        let attachments = AttachmentNormalizer.normalize(message: fixture.message)
        try fixture.state.archive(message: fixture.message, attachments: attachments)
        let unsafeNames = [
            "/Users/example/secret.txt",
            "../relative-secret.txt",
            "folder/relative-secret.txt",
            #"C:\Users\example\secret.txt"#,
            #"..\relative-secret.txt"#,
            "folder%2Fencoded-secret.txt",
        ]
        let unsafeAttachments = unsafeNames.enumerated().map {
            NormalizedAttachment(id: "unsafe-name-\($0.offset)", kind: .file, name: $0.element)
        }
        let safeName = NormalizedAttachment(id: "safe-name", kind: .file, name: "report.pdf")
        try GenericWebhook(state: fixture.state, transport: MockWebhook()).enqueue(
            message: fixture.message,
            attachments: attachments + unsafeAttachments + [safeName]
        )
        let pending = try fixture.state.pendingWebhooks()
        #expect(pending.count == 1)
        let text = String(decoding: pending[0].payload, as: UTF8.self)
        #expect(!text.contains("cdn.example.com"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains(fixture.paths.archiveRoot.path))
        #expect(!text.contains("archiveRoot"))
        #expect(text.contains("attachments"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(WebhookEnvelope.self, from: pending[0].payload)
        #expect(envelope.attachments.filter { $0.id.hasPrefix("unsafe-name-") }.allSatisfy { $0.name == nil })
        #expect(envelope.attachments.first { $0.id == "safe-name" }?.name == "report.pdf")
        #expect(WebhookEndpointPolicy.permits(URL(string: "https://hooks.example.com/events")!))
        #expect(!WebhookEndpointPolicy.permits(URL(string: "https://user:secret@hooks.example.com/events")!))
    }

    @Test("legacy media re-audit preserves outgoing direction and does not expand allowlist")
    func legacyDirectionReaudit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacyRoot = fixture.root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let object = legacyRoot.appendingPathComponent("video.bin")
        let bytes = Data("abc".utf8)
        try bytes.write(to: object)
        let sha1 = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        let messages = fixture.root.appendingPathComponent("legacy-messages.sqlite")
        try runSQLite(
            path: messages.path,
            sql: """
            CREATE TABLE messages(log_id INTEGER PRIMARY KEY, chat_id INTEGER, message_timestamp TEXT, payload_json TEXT);
            CREATE TABLE outbox(id INTEGER PRIMARY KEY, delivered_at REAL);
            INSERT INTO messages VALUES(77, 44, '2026-08-03T00:00:00Z', '{"sender_id":9,"sender":"Me","text":"video","message_type":3,"is_from_me":true}');
            """
        )
        let media = fixture.root.appendingPathComponent("legacy-media.sqlite")
        try runSQLite(
            path: media.path,
            sql: """
            CREATE TABLE archive_items(
                log_id INTEGER, chat_id INTEGER, sent_at_utc TEXT, duration_seconds INTEGER,
                width INTEGER, height INTEGER, expected_bytes INTEGER, source_sha1 TEXT,
                status TEXT, error TEXT, sha256 TEXT, object_path TEXT
            );
            INSERT INTO archive_items VALUES(
                77, 44, '2026-08-03T00:00:00Z', 1, 10, 10, 3, '\(sha1)',
                'complete', NULL, '\(sha256)', '\(object.path)'
            );
            """
        )

        // Reproduce the old empty-payload direction corruption first.
        try fixture.state.importMessage(
            logID: 77,
            chatID: ChatID(rawValue: 44),
            timestamp: Date(timeIntervalSince1970: 0),
            payload: Data("{}".utf8)
        )
        #expect(try fixture.state.archivedWebhookRecord(logID: 77)?.message.isFromMe == false)

        let report = try LegacyMigrator(state: fixture.state, archiveRoot: fixture.paths.archiveRoot).migrate(
            messagesDatabase: messages,
            mediaDatabase: media,
            mediaRoot: legacyRoot
        )
        #expect(report.mediaCompleteImported == 1)
        #expect(report.allowedChatsImported == 0)
        #expect(try fixture.state.allowedChats().isEmpty)
        #expect(try fixture.state.archivedWebhookRecord(logID: 77)?.message.isFromMe == true)
    }

    private func message(
        id: Int64,
        type: Message.MessageType,
        text: String? = nil,
        attachment: String? = #"{"url":"https://cdn.example.com/video","s":3}"#
    ) -> Message {
        Message(
            id: id,
            chatId: ChatID(rawValue: 44),
            senderId: 9,
            senderName: "Sender",
            text: text,
            type: type,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isFromMe: false,
            rawAttachment: attachment
        )
    }

    private func runSQLite(path: String, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
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

    private struct Fixture {
        let root: URL
        let paths: RuntimePaths
        let state: StateStore
        let message: Message

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            paths = RuntimePaths(
                stateDirectory: root.appendingPathComponent("state", isDirectory: true),
                archiveRoot: root.appendingPathComponent("archive", isDirectory: true)
            )
            try paths.prepare()
            state = try StateStore(
                path: paths.stateDatabase.path,
                key: String(repeating: "a", count: 64),
                archiveRoot: paths.archiveRoot.path
            )
            message = Message(
                id: 1,
                chatId: ChatID(rawValue: 44),
                senderId: 9,
                senderName: "Sender",
                text: "hello",
                type: .video,
                createdAt: Date(),
                isFromMe: false,
                rawAttachment: #"{"url":"https://cdn.example.com/video","s":3}"#
            )
        }

        func cleanup() {
            state.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private struct MockFetcher: MediaFetching {
    let result: Result<MediaFetchResponse, Error>
    func fetch(_ url: URL) throws -> MediaFetchResponse { try result.get() }
}

private final class CountingFetcher: MediaFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func fetch(_ url: URL) throws -> MediaFetchResponse {
        lock.lock(); value += 1; lock.unlock()
        throw MediaArchiveError.downloadFailed("fetch should not run")
    }
}

private struct MockDisk: DiskCapacityChecking {
    let bytes: Int64?
    func availableBytes(at url: URL) -> Int64? { bytes }
}

private struct MockWebhook: WebhookTransporting {
    func post(url: URL, bearerToken: String?, eventID: String, payload: Data) throws {}
}
