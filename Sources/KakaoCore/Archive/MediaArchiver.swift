import CryptoKit
import Foundation

public struct MediaFetchResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let finalURL: URL
}

public protocol MediaFetching: Sendable {
    func fetch(_ url: URL) throws -> MediaFetchResponse
}

public struct HTTPSMediaFetcher: MediaFetching {
    public init() {}

    public func fetch(_ url: URL) throws -> MediaFetchResponse {
        guard url.scheme?.lowercased() == "https" else {
            throw MediaArchiveError.insecureURL
        }
        let delegate = HTTPSRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<MediaFetchResponse, Error>?
        let task = session.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse,
                  let finalURL = http.url,
                  finalURL.scheme?.lowercased() == "https" else {
                result = .failure(MediaArchiveError.insecureRedirect)
                return
            }
            result = .success(MediaFetchResponse(
                data: data ?? Data(),
                statusCode: http.statusCode,
                finalURL: finalURL
            ))
        }
        task.resume()
        semaphore.wait()
        session.finishTasksAndInvalidate()
        return try result?.get() ?? { throw MediaArchiveError.downloadFailed("No response") }()
    }
}

private final class HTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

public protocol DiskCapacityChecking: Sendable {
    func availableBytes(at url: URL) -> Int64?
}

public struct SystemDiskCapacity: DiskCapacityChecking {
    public init() {}
    public func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

public enum MediaArchiveError: Error, CustomStringConvertible, Equatable {
    case insecureURL
    case insecureRedirect
    case expired
    case partialDownload(expected: Int64, actual: Int64)
    case checksumMismatch
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .insecureURL: return "Only HTTPS media URLs are allowed"
        case .insecureRedirect: return "Media redirect left HTTPS"
        case .expired: return "Media URL expired"
        case .partialDownload(let expected, let actual):
            return "Expected \(expected) bytes but received \(actual)"
        case .checksumMismatch: return "Reported media checksum did not match"
        case .downloadFailed(let message): return message
        }
    }
}

public final class MediaArchiver: @unchecked Sendable {
    private let state: StateStore
    private let root: URL
    private let fetcher: MediaFetching
    private let disk: DiskCapacityChecking
    private let criticalFreeBytes: Int64

    public init(
        state: StateStore,
        root: URL,
        fetcher: MediaFetching = HTTPSMediaFetcher(),
        disk: DiskCapacityChecking = SystemDiskCapacity(),
        criticalFreeBytes: Int64 = 512 * 1_024 * 1_024
    ) {
        self.state = state
        self.root = root
        self.fetcher = fetcher
        self.disk = disk
        self.criticalFreeBytes = criticalFreeBytes
    }

    public func processPending(limit: Int = 20) throws {
        for pending in try state.pendingAttachments(limit: limit) {
            let attachment = pending.attachment
            guard attachment.remoteURL != nil || attachment.localPath != nil else {
                try state.updateAttachment(
                    id: pending.id,
                    status: attachment.kind == .link || attachment.kind == .linkPreview ? "metadata_only" : "unretrievable",
                    incrementAttempt: false
                )
                continue
            }
            if let available = disk.availableBytes(at: root), available < criticalFreeBytes {
                try state.updateAttachment(
                    id: pending.id,
                    status: "paused_low_disk",
                    error: "Downloads paused because free disk space is critically low",
                    incrementAttempt: false
                )
                continue
            }

            do {
                let data: Data
                if let remote = attachment.remoteURL {
                    let response = try fetcher.fetch(remote)
                    if response.statusCode == 410 { throw MediaArchiveError.expired }
                    guard (200..<300).contains(response.statusCode) else {
                        throw MediaArchiveError.downloadFailed("Media server returned HTTP \(response.statusCode)")
                    }
                    data = response.data
                } else if let localPath = attachment.localPath {
                    data = try Data(contentsOf: URL(fileURLWithPath: localPath), options: [.mappedIfSafe])
                } else {
                    continue
                }

                if let expected = attachment.expectedBytes, expected > 0, Int64(data.count) != expected {
                    throw MediaArchiveError.partialDownload(expected: expected, actual: Int64(data.count))
                }
                if let checksum = attachment.checksum,
                   checksum.value.lowercased() != digest(data: data, algorithm: checksum.algorithm) {
                    throw MediaArchiveError.checksumMismatch
                }

                let sha256 = digest(data: data, algorithm: "sha256")
                let prefix = String(sha256.prefix(2))
                let objectDirectory = root.appendingPathComponent("objects/\(prefix)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: objectDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                _ = chmod(objectDirectory.path, 0o700)
                let objectURL = objectDirectory.appendingPathComponent(sha256)
                if !FileManager.default.fileExists(atPath: objectURL.path) {
                    let temporary = objectDirectory.appendingPathComponent(".\(sha256).\(UUID().uuidString).partial")
                    try data.write(to: temporary, options: [.atomic])
                    _ = chmod(temporary.path, 0o600)
                    do {
                        try FileManager.default.moveItem(at: temporary, to: objectURL)
                    } catch CocoaError.fileWriteFileExists {
                        try? FileManager.default.removeItem(at: temporary)
                    }
                    _ = chmod(objectURL.path, 0o600)
                }
                let relative = "objects/\(prefix)/\(sha256)"
                try state.registerObject(sha256: sha256, bytes: Int64(data.count), relativePath: relative)
                try state.updateAttachment(id: pending.id, status: "complete", sha256: sha256)
            } catch let error as MediaArchiveError {
                try state.updateAttachment(
                    id: pending.id,
                    status: error == .expired ? "expired" : "download_failed",
                    error: error.description
                )
            } catch {
                try state.updateAttachment(id: pending.id, status: "download_failed", error: String(describing: error))
            }
        }
    }

    private func digest(data: Data, algorithm: String) -> String {
        let bytes: [UInt8]
        switch algorithm.lowercased() {
        case "sha1", "sha-1": bytes = Array(Insecure.SHA1.hash(data: data))
        case "md5": bytes = Array(Insecure.MD5.hash(data: data))
        default: bytes = Array(SHA256.hash(data: data))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
