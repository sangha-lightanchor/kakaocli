import Darwin
import Foundation

public struct ServiceStatus: Codable, Sendable {
    public let running: Bool
    public let processID: Int32
    public let socketPath: String
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

public final class LocalServiceServer: @unchecked Sendable {
    private let socketURL: URL

    public init(socketURL: URL) {
        self.socketURL = socketURL
    }

    public func run(client: KakaoClient) throws -> Never {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw KakaoClientError.state("Could not create the service socket") }
        defer { Darwin.close(descriptor) }

        if FileManager.default.fileExists(atPath: socketURL.path) {
            guard !LocalServiceConnection(socketURL: socketURL).isAvailable else {
                throw KakaoClientError.state("The kakaocli service is already running")
            }
            try FileManager.default.removeItem(at: socketURL)
        }

        var address = try unixAddress(path: socketURL.path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw KakaoClientError.state("Could not bind the service socket")
        }
        guard chmod(socketURL.path, 0o600) == 0, Darwin.listen(descriptor, 16) == 0 else {
            throw KakaoClientError.state("Could not secure or listen on the service socket")
        }
        defer { try? FileManager.default.removeItem(at: socketURL) }

        Task.detached {
            let stream = await client.events()
            do {
                for try await _ in stream {}
            } catch {
                // Socket requests remain available; status exposes archive state.
            }
        }

        while true {
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                throw KakaoClientError.state("Service accept failed")
            }
            autoreleasepool {
                defer { Darwin.close(connection) }
                do {
                    let requestData = try readLine(from: connection)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let request = try decoder.decode(LocalServiceRequest.self, from: requestData)
                    let response = try handle(request, client: client)
                    try write(response, to: connection)
                } catch {
                    try? write(
                        LocalServiceResponse(ok: false, payload: nil, error: String(describing: error)),
                        to: connection
                    )
                }
            }
        }
    }

    private func handle(_ request: LocalServiceRequest, client: KakaoClient) throws -> LocalServiceResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload: Data
        switch request.method {
        case "status":
            payload = try encoder.encode(ServiceStatus(
                running: true,
                processID: getpid(),
                socketPath: socketURL.path
            ))
        case "chats":
            payload = try encoder.encode(try waitForValue {
                try await client.listChats(search: request.search, limit: request.limit ?? 50)
            })
        case "messages":
            payload = try encoder.encode(try waitForValue {
                try await client.messages(chatID: request.chatID, since: request.since, limit: request.limit ?? 50)
            })
        case "send":
            guard let sendRequest = request.sendRequest else {
                throw KakaoClientError.invalidRequest("Service send request is missing its payload")
            }
            payload = try encoder.encode(try waitForValue { try await client.send(sendRequest) })
        case "archive_status":
            payload = try encoder.encode(try waitForValue { try await client.archiveStatus() })
        default:
            throw KakaoClientError.invalidRequest("Unknown service method")
        }
        return LocalServiceResponse(ok: true, payload: payload, error: nil)
    }

    private func waitForValue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task {
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result?.get() ?? { throw KakaoClientError.state("Service operation did not complete") }()
    }

    private func readLine(from descriptor: Int32) throws -> Data {
        var output = Data()
        var byte: UInt8 = 0
        while output.count <= 1_048_576 {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw KakaoClientError.state("Service socket read failed")
            }
            if byte == 0x0A { return output }
            output.append(byte)
        }
        guard output.count <= 1_048_576 else {
            throw KakaoClientError.invalidRequest("Service request exceeded 1 MiB")
        }
        return output
    }

    private func write(_ response: LocalServiceResponse, to descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(response)
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < data.count {
                let result = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), data.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw KakaoClientError.state("Service socket write failed")
                }
                written += result
            }
        }
    }
}

public final class LocalServiceConnection: @unchecked Sendable {
    private let socketURL: URL

    public init(socketURL: URL) {
        self.socketURL = socketURL
    }

    public var isAvailable: Bool {
        (try? callRaw(LocalServiceRequest(method: "status")))?.ok == true
    }

    public func call<Response: Decodable>(_ request: LocalServiceRequest, as type: Response.Type) throws -> Response {
        let response = try callRaw(request)
        guard response.ok, let payload = response.payload else {
            throw KakaoClientError.state(response.error ?? "Service request failed")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: payload)
    }

    private func callRaw(_ request: LocalServiceRequest) throws -> LocalServiceResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw KakaoClientError.state("Could not create a client socket") }
        defer { Darwin.close(descriptor) }
        var address = try unixAddress(path: socketURL.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw KakaoClientError.state("kakaocli service is not running") }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(request)
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < data.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), data.count - written)
                guard count > 0 else { throw KakaoClientError.state("Service request write failed") }
                written += count
            }
        }
        let responseData = try readResponse(from: descriptor)
        return try JSONDecoder().decode(LocalServiceResponse.self, from: responseData)
    }

    private func readResponse(from descriptor: Int32) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while output.count <= 2_097_152 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw KakaoClientError.state("Service response read failed") }
            output.append(contentsOf: buffer.prefix(count))
            if output.last == 0x0A { output.removeLast(); return output }
        }
        return output
    }
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
