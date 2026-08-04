import CryptoKit
import Darwin
import Foundation

public struct MediaFetchResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let finalURL: URL

    public init(data: Data, statusCode: Int, finalURL: URL) {
        self.data = data
        self.statusCode = statusCode
        self.finalURL = finalURL
    }
}

public protocol MediaFetching: Sendable {
    func fetch(_ url: URL) throws -> MediaFetchResponse
}

public struct MediaFileFetchResponse: Sendable {
    public let statusCode: Int
    public let finalURL: URL
    public let byteCount: Int64
}

public protocol StreamingMediaFetching: MediaFetching {
    func fetch(
        _ url: URL,
        to destination: URL,
        maximumBytes: Int64,
        minimumFreeBytes: Int64
    ) throws -> MediaFileFetchResponse
}

/// Restricts archive downloads to known Kakao-controlled HTTPS hosts and
/// rejects hostnames that resolve to non-public address space.
public struct MediaURLPolicy: Sendable {
    public static let live = MediaURLPolicy(approvedDomainSuffixes: [
        "kakao.com", "kakaocdn.com", "kakaocdn.net", "daumcdn.net",
    ])

    private let approvedDomainSuffixes: Set<String>
    private let resolveAddresses: Bool

    public init(approvedDomainSuffixes: Set<String>, resolveAddresses: Bool = true) {
        self.approvedDomainSuffixes = Set(approvedDomainSuffixes.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        })
        self.resolveAddresses = resolveAddresses
    }

    public func permits(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty,
              approvedDomainSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }),
              !Self.isObviouslyLocal(host) else { return false }
        return !resolveAddresses || Self.resolvesOnlyToPublicAddresses(host)
    }

    private static func isObviouslyLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "127.0.0.1"
    }

    private static func resolvesOnlyToPublicAddresses(_ host: String) -> Bool {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let entry = current {
            found = true
            guard let address = entry.pointee.ai_addr, isPublic(address) else { return false }
            current = entry.pointee.ai_next
        }
        return found
    }

    private static func isPublic(_ address: UnsafePointer<sockaddr>) -> Bool {
        if address.pointee.sa_family == sa_family_t(AF_INET) {
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            return isPublicIPv4(value)
        }
        if address.pointee.sa_family == sa_family_t(AF_INET6) {
            let value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            }
            guard value.count == 16 else { return false }
            if value.allSatisfy({ $0 == 0 }) || value == Array(repeating: 0, count: 15) + [1] { return false }
            if value[0] & 0xfe == 0xfc || (value[0] == 0xfe && value[1] & 0xc0 == 0x80) || value[0] == 0xff {
                return false
            }
            if value.prefix(10).allSatisfy({ $0 == 0 }), value[10] == 0xff, value[11] == 0xff {
                let mapped = value[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return isPublicIPv4(mapped)
            }
            return true
        }
        return false
    }

    private static func isPublicIPv4(_ value: UInt32) -> Bool {
        let first = value >> 24
        let second = (value >> 16) & 0xff
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && (second == 0 || second == 168) { return false }
        if first == 198 && (second == 18 || second == 19 || second == 51) { return false }
        if first == 203 && second == 0 { return false }
        return true
    }
}

public struct HTTPSMediaFetcher: StreamingMediaFetching {
    private let policy: MediaURLPolicy
    private let disk: any DiskCapacityChecking

    public init(policy: MediaURLPolicy = .live, disk: any DiskCapacityChecking = SystemDiskCapacity()) {
        self.policy = policy
        self.disk = disk
    }

    /// Compatibility API. Production archival uses the bounded streaming API.
    public func fetch(_ url: URL) throws -> MediaFetchResponse {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("kakaocli-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let response = try fetch(
            url,
            to: temporary,
            maximumBytes: 64 * 1_024 * 1_024,
            minimumFreeBytes: 512 * 1_024 * 1_024
        )
        return MediaFetchResponse(
            data: try Data(contentsOf: temporary, options: [.mappedIfSafe]),
            statusCode: response.statusCode,
            finalURL: response.finalURL
        )
    }

    public func fetch(
        _ url: URL,
        to destination: URL,
        maximumBytes: Int64,
        minimumFreeBytes: Int64
    ) throws -> MediaFileFetchResponse {
        guard policy.permits(url) else { throw MediaArchiveError.insecureURL }
        let delegate = BoundedDownloadDelegate(
            destination: destination,
            policy: policy,
            disk: disk,
            maximumBytes: maximumBytes,
            minimumFreeBytes: minimumFreeBytes
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        session.downloadTask(with: url).resume()
        delegate.wait()
        session.finishTasksAndInvalidate()
        return try delegate.result.get()
    }
}

private final class BoundedDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let policy: MediaURLPolicy
    private let disk: any DiskCapacityChecking
    private let maximumBytes: Int64
    private let minimumFreeBytes: Int64
    private let semaphore = DispatchSemaphore(value: 0)
    private var storedError: Error?
    private var copied = false
    var result: Result<MediaFileFetchResponse, Error> = .failure(MediaArchiveError.downloadFailed("No response"))

    init(
        destination: URL,
        policy: MediaURLPolicy,
        disk: any DiskCapacityChecking,
        maximumBytes: Int64,
        minimumFreeBytes: Int64
    ) {
        self.destination = destination
        self.policy = policy
        self.disk = disk
        self.maximumBytes = maximumBytes
        self.minimumFreeBytes = minimumFreeBytes
    }

    func wait() { semaphore.wait() }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, policy.permits(url) else {
            storedError = MediaArchiveError.insecureRedirect
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            storedError = MediaArchiveError.tooLarge(maximum: maximumBytes)
            downloadTask.cancel()
            return
        }
        if let available = disk.availableBytes(at: destination.deletingLastPathComponent()),
           available < minimumFreeBytes {
            storedError = MediaArchiveError.lowDisk
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard storedError == nil,
              let response = downloadTask.response as? HTTPURLResponse,
              let finalURL = response.url,
              policy.permits(finalURL) else {
            storedError = storedError ?? MediaArchiveError.insecureRedirect
            return
        }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
            guard size <= maximumBytes else { throw MediaArchiveError.tooLarge(maximum: maximumBytes) }
            try FileManager.default.copyItem(at: location, to: destination)
            _ = chmod(destination.path, 0o600)
            copied = true
            result = .success(MediaFileFetchResponse(
                statusCode: response.statusCode,
                finalURL: finalURL,
                byteCount: size
            ))
        } catch {
            storedError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { semaphore.signal() }
        if let storedError {
            try? FileManager.default.removeItem(at: destination)
            result = .failure(storedError)
        } else if let error, !copied {
            result = .failure(error)
        }
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
    case unsafeLocalPath
    case expired
    case lowDisk
    case tooLarge(maximum: Int64)
    case partialDownload(expected: Int64, actual: Int64)
    case checksumMismatch
    case corruptObject
    case httpStatus(Int)
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .insecureURL: return "Media URL was not an approved public HTTPS endpoint"
        case .insecureRedirect: return "Media redirect was not an approved public HTTPS endpoint"
        case .unsafeLocalPath: return "Local media path was outside an approved Kakao container"
        case .expired: return "Media URL expired"
        case .lowDisk: return "Downloads paused because free disk space is critically low"
        case .tooLarge(let maximum): return "Media exceeded the \(maximum)-byte archive limit"
        case .partialDownload(let expected, let actual): return "Expected \(expected) bytes but received \(actual)"
        case .checksumMismatch: return "Reported media checksum did not match"
        case .corruptObject: return "Existing content-addressed object failed integrity verification"
        case .httpStatus(let value): return "Media server returned HTTP \(value)"
        case .downloadFailed(let message): return message
        }
    }
}

public final class MediaArchiver: @unchecked Sendable {
    private let state: StateStore
    private let root: URL
    private let fetcher: any MediaFetching
    private let disk: any DiskCapacityChecking
    private let criticalFreeBytes: Int64
    private let maximumObjectBytes: Int64
    private let allowedLocalRoots: [URL]

    public init(
        state: StateStore,
        root: URL,
        fetcher: any MediaFetching = HTTPSMediaFetcher(),
        disk: any DiskCapacityChecking = SystemDiskCapacity(),
        criticalFreeBytes: Int64 = 512 * 1_024 * 1_024,
        maximumObjectBytes: Int64 = 1_024 * 1_024 * 1_024,
        allowedLocalRoots: [URL]? = nil
    ) {
        self.state = state
        self.root = root
        self.fetcher = fetcher
        self.disk = disk
        self.criticalFreeBytes = criticalFreeBytes
        self.maximumObjectBytes = maximumObjectBytes
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.allowedLocalRoots = allowedLocalRoots ?? [
            home.appendingPathComponent("Library/Containers/com.kakao.KakaoTalkMac/Data", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/KakaoTalk", isDirectory: true),
        ]
    }

    @discardableResult
    public func processPending(limit: Int = 20) throws -> Set<Int64> {
        var changed: Set<Int64> = []
        for pending in try state.pendingAttachments(limit: limit) {
            let attachment = pending.attachment
            if attachment.kind == .link || attachment.kind == .linkPreview {
                try state.updateAttachment(id: pending.id, status: "metadata_only", incrementAttempt: false)
                changed.insert(pending.logID)
                continue
            }
            guard attachment.remoteURL != nil || attachment.localPath != nil else {
                try state.updateAttachment(id: pending.id, status: "unretrievable", incrementAttempt: false)
                changed.insert(pending.logID)
                continue
            }
            if let expected = attachment.expectedBytes, expected > maximumObjectBytes {
                try state.updateAttachment(
                    id: pending.id,
                    status: "too_large",
                    error: MediaArchiveError.tooLarge(maximum: maximumObjectBytes).description
                )
                changed.insert(pending.logID)
                continue
            }
            if let available = disk.availableBytes(at: root),
               available < criticalFreeBytes + max(0, attachment.expectedBytes ?? 0) {
                try state.updateAttachment(
                    id: pending.id,
                    status: "paused_low_disk",
                    error: MediaArchiveError.lowDisk.description,
                    incrementAttempt: false,
                    retryAt: Date().addingTimeInterval(60)
                )
                changed.insert(pending.logID)
                continue
            }

            let temporary = try makeTemporaryObjectURL()
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let actualBytes: Int64
                if let remote = attachment.remoteURL {
                    guard let streaming = fetcher as? any StreamingMediaFetching else {
                        let response = try fetcher.fetch(remote)
                        guard response.data.count <= maximumObjectBytes else {
                            throw MediaArchiveError.tooLarge(maximum: maximumObjectBytes)
                        }
                        guard (200..<300).contains(response.statusCode) else {
                            throw MediaArchiveError.httpStatus(response.statusCode)
                        }
                        try response.data.write(to: temporary, options: [.atomic])
                        _ = chmod(temporary.path, 0o600)
                        actualBytes = Int64(response.data.count)
                        try verifyFreeSpace(afterWriting: actualBytes)
                        try verifyExpectedURL(response.finalURL, original: remote)
                        try verifyFile(at: temporary, attachment: attachment, actualBytes: actualBytes)
                        let sha256 = try digest(file: temporary, algorithm: "sha256")
                        try installObject(from: temporary, sha256: sha256, bytes: actualBytes)
                        try state.updateAttachment(id: pending.id, status: "complete", sha256: sha256)
                        changed.insert(pending.logID)
                        continue
                    }
                    let response = try streaming.fetch(
                        remote,
                        to: temporary,
                        maximumBytes: maximumObjectBytes,
                        minimumFreeBytes: criticalFreeBytes
                    )
                    guard (200..<300).contains(response.statusCode) else {
                        throw MediaArchiveError.httpStatus(response.statusCode)
                    }
                    actualBytes = response.byteCount
                } else if let localPath = attachment.localPath {
                    actualBytes = try copyApprovedLocalFile(path: localPath, to: temporary)
                } else {
                    continue
                }

                try verifyFile(at: temporary, attachment: attachment, actualBytes: actualBytes)
                let sha256 = try digest(file: temporary, algorithm: "sha256")
                try installObject(from: temporary, sha256: sha256, bytes: actualBytes)
                try state.updateAttachment(id: pending.id, status: "complete", sha256: sha256)
                changed.insert(pending.logID)
            } catch let error as MediaArchiveError {
                let disposition = disposition(for: error, attempts: pending.attempts)
                try state.updateAttachment(
                    id: pending.id,
                    status: disposition.status,
                    error: error.description,
                    incrementAttempt: disposition.incrementAttempt,
                    retryAt: disposition.retryAt
                )
                changed.insert(pending.logID)
            } catch {
                let retry = Date().addingTimeInterval(retryDelay(attempts: pending.attempts))
                try state.updateAttachment(
                    id: pending.id,
                    status: "download_failed",
                    error: String(describing: error),
                    retryAt: retry
                )
                changed.insert(pending.logID)
            }
        }
        return changed
    }

    private func disposition(for error: MediaArchiveError, attempts: Int) -> (status: String, incrementAttempt: Bool, retryAt: Date?) {
        switch error {
        case .expired, .httpStatus(401), .httpStatus(403), .httpStatus(404), .httpStatus(410):
            return ("expired", true, nil)
        case .insecureURL, .insecureRedirect, .unsafeLocalPath, .tooLarge,
             .partialDownload, .checksumMismatch, .corruptObject:
            return ("verification_failed", true, nil)
        case .httpStatus(let code) where (400..<500).contains(code)
            && ![408, 409, 425, 429].contains(code):
            return ("unretrievable", true, nil)
        case .lowDisk:
            return ("paused_low_disk", false, Date().addingTimeInterval(60))
        default:
            return ("download_failed", true, Date().addingTimeInterval(retryDelay(attempts: attempts)))
        }
    }

    private func retryDelay(attempts: Int) -> TimeInterval {
        min(pow(2, Double(min(attempts + 1, 12))), 3_600) + Double.random(in: 0...1)
    }

    private func makeTemporaryObjectURL() throws -> URL {
        let directory = root.appendingPathComponent("objects/.partial", isDirectory: true)
        try secureDirectory(directory)
        return directory.appendingPathComponent("\(UUID().uuidString).partial")
    }

    private func secureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid() else { throw MediaArchiveError.unsafeLocalPath }
        _ = chmod(directory.path, 0o700)
    }

    private func copyApprovedLocalFile(path: String, to destination: URL) throws -> Int64 {
        let original = URL(fileURLWithPath: path).standardizedFileURL
        guard let canonical = canonicalPath(original), allowedLocalRoots.contains(where: { root in
            guard let canonicalRoot = canonicalPath(root) else { return false }
            return canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/")
        }) else { throw MediaArchiveError.unsafeLocalPath }

        var info = stat()
        guard lstat(original.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_size >= 0,
              info.st_size <= maximumObjectBytes else { throw MediaArchiveError.unsafeLocalPath }
        let descriptor = Darwin.open(original.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MediaArchiveError.unsafeLocalPath }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var total: Int64 = 0
        while true {
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            total += Int64(data.count)
            guard total <= maximumObjectBytes else { throw MediaArchiveError.tooLarge(maximum: maximumObjectBytes) }
            try verifyFreeSpace(afterWriting: Int64(data.count))
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        return total
    }

    private func verifyFreeSpace(afterWriting bytes: Int64) throws {
        if let available = disk.availableBytes(at: root), available - bytes < criticalFreeBytes {
            throw MediaArchiveError.lowDisk
        }
    }

    private func verifyExpectedURL(_ finalURL: URL, original: URL) throws {
        guard finalURL.scheme?.lowercased() == "https" else { throw MediaArchiveError.insecureRedirect }
        if fetcher is HTTPSMediaFetcher {
            guard MediaURLPolicy.live.permits(finalURL) else { throw MediaArchiveError.insecureRedirect }
        }
    }

    private func verifyFile(at url: URL, attachment: NormalizedAttachment, actualBytes: Int64) throws {
        if let expected = attachment.expectedBytes, expected > 0, actualBytes != expected {
            throw MediaArchiveError.partialDownload(expected: expected, actual: actualBytes)
        }
        if let checksum = attachment.checksum,
           checksum.value.lowercased() != (try digest(file: url, algorithm: checksum.algorithm)) {
            throw MediaArchiveError.checksumMismatch
        }
    }

    private func installObject(from temporary: URL, sha256: String, bytes: Int64) throws {
        let prefix = String(sha256.prefix(2))
        let directory = root.appendingPathComponent("objects/\(prefix)", isDirectory: true)
        try secureDirectory(directory)
        let object = directory.appendingPathComponent(sha256)
        if pathExistsWithoutFollowing(object) {
            if try isValidObject(object, sha256: sha256, bytes: bytes) {
                try? FileManager.default.removeItem(at: temporary)
            } else {
                let quarantine = directory.appendingPathComponent(".\(sha256).corrupt.\(UUID().uuidString)")
                try FileManager.default.moveItem(at: object, to: quarantine)
                _ = chmod(quarantine.path, 0o600)
                try FileManager.default.moveItem(at: temporary, to: object)
            }
        } else {
            do {
                try FileManager.default.moveItem(at: temporary, to: object)
            } catch {
                guard pathExistsWithoutFollowing(object), try isValidObject(object, sha256: sha256, bytes: bytes) else {
                    throw error
                }
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        _ = chmod(object.path, 0o600)
        guard try isValidObject(object, sha256: sha256, bytes: bytes) else { throw MediaArchiveError.corruptObject }
        try state.registerObject(
            sha256: sha256,
            bytes: bytes,
            relativePath: "objects/\(prefix)/\(sha256)"
        )
    }

    private func isValidObject(_ url: URL, sha256: String, bytes: Int64) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_size == bytes else { return false }
        return try digest(file: url, algorithm: "sha256") == sha256
    }

    private func digest(file: URL, algorithm: String) throws -> String {
        switch algorithm.lowercased() {
        case "sha1", "sha-1": return try hashFile(file, using: Insecure.SHA1.self)
        case "md5": return try hashFile(file, using: Insecure.MD5.self)
        case "sha256", "sha-256": return try hashFile(file, using: SHA256.self)
        default: throw MediaArchiveError.checksumMismatch
        }
    }

    private func hashFile<H: HashFunction>(_ file: URL, using type: H.Type) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = H()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func canonicalPath(_ url: URL) -> String? {
        guard let value = realpath(url.path, nil) else { return nil }
        defer { free(value) }
        return String(cString: value)
    }

    private func pathExistsWithoutFollowing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
