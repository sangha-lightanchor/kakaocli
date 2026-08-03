import CryptoKit
import Foundation

public enum AttachmentKind: String, Codable, Sendable, CaseIterable {
    case link
    case linkPreview = "link_preview"
    case photo
    case multiPhoto = "multi_photo"
    case video
    case audio
    case file
    case sticker
    case localFile = "local_file"
    case unknown
}

public struct ReportedChecksum: Codable, Sendable, Equatable {
    public let algorithm: String
    public let value: String
}

public struct NormalizedAttachment: Codable, Sendable, Equatable {
    public let id: String
    public let kind: AttachmentKind
    public let remoteURL: URL?
    public let localPath: String?
    public let name: String?
    public let mimeType: String?
    public let expectedBytes: Int64?
    public let checksum: ReportedChecksum?
    public let width: Int?
    public let height: Int?
    public let durationMilliseconds: Int64?

    public init(
        id: String,
        kind: AttachmentKind,
        remoteURL: URL? = nil,
        localPath: String? = nil,
        name: String? = nil,
        mimeType: String? = nil,
        expectedBytes: Int64? = nil,
        checksum: ReportedChecksum? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationMilliseconds: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.remoteURL = remoteURL
        self.localPath = localPath
        self.name = name
        self.mimeType = mimeType
        self.expectedBytes = expectedBytes
        self.checksum = checksum
        self.width = width
        self.height = height
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum AttachmentNormalizer {
    public static func normalize(message: Message) -> [NormalizedAttachment] {
        guard let raw = message.rawAttachment,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return links(in: message.text).enumerated().map { index, url in
                make(idSeed: "\(message.id):text:\(index):\(url.absoluteString)", kind: .link, remoteURL: url)
            }
        }

        var output: [NormalizedAttachment] = []
        visit(object, message: message, path: "root", inheritedKind: kind(for: message.type), output: &output)

        let existingURLs = Set(output.compactMap { $0.remoteURL?.absoluteString })
        for (index, url) in links(in: message.text).enumerated() where !existingURLs.contains(url.absoluteString) {
            output.append(make(
                idSeed: "\(message.id):text:\(index):\(url.absoluteString)",
                kind: .link,
                remoteURL: url
            ))
        }
        return deduplicate(output)
    }

    private static func visit(
        _ value: Any,
        message: Message,
        path: String,
        inheritedKind: AttachmentKind,
        output: inout [NormalizedAttachment]
    ) {
        if let array = value as? [Any] {
            let arrayKind: AttachmentKind = inheritedKind == .photo && array.count > 1 ? .multiPhoto : inheritedKind
            for (index, item) in array.enumerated() {
                visit(item, message: message, path: "\(path).\(index)", inheritedKind: arrayKind, output: &output)
            }
            return
        }
        guard let dictionary = value as? [String: Any] else { return }

        let kind = inferredKind(dictionary, fallback: inheritedKind)
        let urlString = string(dictionary, keys: ["url", "downloadUrl", "download_url", "playUrl", "play_url"])
        let localPath = string(dictionary, keys: ["path", "localPath", "local_path"])
        let remoteURL = urlString.flatMap(URL.init(string:)).flatMap { url in
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        let localFile = localPath.flatMap { path -> String? in
            let expanded = NSString(string: path).expandingTildeInPath
            return expanded.hasPrefix("/") ? expanded : nil
        }

        if remoteURL != nil || localFile != nil || kind == .sticker || kind == .linkPreview {
            let checksum = reportedChecksum(dictionary)
            let seed = "\(message.id):\(path):\(remoteURL?.absoluteString ?? localFile ?? kind.rawValue)"
            output.append(make(
                idSeed: seed,
                kind: localFile == nil ? kind : .localFile,
                remoteURL: remoteURL,
                localPath: localFile,
                name: string(dictionary, keys: ["name", "filename", "fileName", "title"]),
                mimeType: string(dictionary, keys: ["mime", "mimeType", "contentType"]),
                expectedBytes: int64(dictionary, keys: ["s", "size", "fileSize", "contentLength"]),
                checksum: checksum,
                width: int(dictionary, keys: ["w", "width"]),
                height: int(dictionary, keys: ["h", "height"]),
                durationMilliseconds: int64(dictionary, keys: ["d", "duration", "durationMs"])
            ))
        }

        for (key, child) in dictionary {
            if child is [Any] || child is [String: Any] {
                visit(child, message: message, path: "\(path).\(key)", inheritedKind: kind, output: &output)
            }
        }
    }

    private static func inferredKind(_ dictionary: [String: Any], fallback: AttachmentKind) -> AttachmentKind {
        let joined = ["type", "mediaType", "attachmentType", "contentType"]
            .compactMap { dictionary[$0] as? String }
            .joined(separator: " ")
            .lowercased()
        if joined.contains("preview") { return .linkPreview }
        if joined.contains("video") { return .video }
        if joined.contains("audio") || joined.contains("voice") { return .audio }
        if joined.contains("photo") || joined.contains("image") { return .photo }
        if joined.contains("sticker") || joined.contains("emoticon") { return .sticker }
        if joined.contains("file") { return .file }
        if joined.contains("link") { return .link }
        return fallback
    }

    private static func kind(for type: Message.MessageType) -> AttachmentKind {
        switch type {
        case .photo: return .photo
        case .video: return .video
        case .voice: return .audio
        case .sticker: return .sticker
        case .file: return .file
        case .text: return .linkPreview
        default: return .unknown
        }
    }

    private static func reportedChecksum(_ dictionary: [String: Any]) -> ReportedChecksum? {
        if let value = string(dictionary, keys: ["sha256"]) {
            return ReportedChecksum(algorithm: "sha256", value: value.lowercased())
        }
        if let value = string(dictionary, keys: ["cs", "sha1", "sha"]), !value.isEmpty {
            return ReportedChecksum(algorithm: "sha1", value: value.lowercased())
        }
        if let value = string(dictionary, keys: ["md5"]), !value.isEmpty {
            return ReportedChecksum(algorithm: "md5", value: value.lowercased())
        }
        return nil
    }

    private static func links(in text: String?) -> [URL] {
        guard let text,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }

    private static func make(
        idSeed: String,
        kind: AttachmentKind,
        remoteURL: URL? = nil,
        localPath: String? = nil,
        name: String? = nil,
        mimeType: String? = nil,
        expectedBytes: Int64? = nil,
        checksum: ReportedChecksum? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationMilliseconds: Int64? = nil
    ) -> NormalizedAttachment {
        let id = SHA256.hash(data: Data(idSeed.utf8)).map { String(format: "%02x", $0) }.joined()
        return NormalizedAttachment(
            id: id,
            kind: kind,
            remoteURL: remoteURL,
            localPath: localPath,
            name: name,
            mimeType: mimeType,
            expectedBytes: expectedBytes,
            checksum: checksum,
            width: width,
            height: height,
            durationMilliseconds: durationMilliseconds
        )
    }

    private static func deduplicate(_ values: [NormalizedAttachment]) -> [NormalizedAttachment] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    private static func string(_ dictionary: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { dictionary[$0] as? String }.first
    }

    private static func int64(_ dictionary: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let value = dictionary[key] as? NSNumber { return value.int64Value }
            if let value = dictionary[key] as? String, let parsed = Int64(value) { return parsed }
        }
        return nil
    }

    private static func int(_ dictionary: [String: Any], keys: [String]) -> Int? {
        int64(dictionary, keys: keys).map(Int.init)
    }
}
