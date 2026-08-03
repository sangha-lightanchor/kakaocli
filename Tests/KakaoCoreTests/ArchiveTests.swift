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

    @Test("partial downloads and checksum failures remain retryable metadata")
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
        #expect(try fixture.state.archiveStatus().pendingDownloadCount == 1)
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
            else { #expect(status.failedDownloadCount == 1) }
        }
    }

    @Test("webhook payload excludes signed URLs and local paths")
    func webhookPrivacy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.state.allow(chatID: fixture.message.chatId)
        try fixture.state.setConfiguration(key: GenericWebhook.URLKey, value: "https://hooks.example.com/events")
        let attachments = AttachmentNormalizer.normalize(message: fixture.message)
        try fixture.state.archive(message: fixture.message, attachments: attachments)
        try GenericWebhook(state: fixture.state, transport: MockWebhook()).enqueue(
            message: fixture.message,
            attachments: attachments
        )
        let pending = try fixture.state.pendingWebhooks()
        #expect(pending.count == 1)
        let text = String(decoding: pending[0].payload, as: UTF8.self)
        #expect(!text.contains("cdn.example.com"))
        #expect(!text.contains("/Users/"))
        #expect(text.contains("attachments"))
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

private struct MockDisk: DiskCapacityChecking {
    let bytes: Int64?
    func availableBytes(at url: URL) -> Int64? { bytes }
}

private struct MockWebhook: WebhookTransporting {
    func post(url: URL, bearerToken: String?, eventID: String, payload: Data) throws {}
}
