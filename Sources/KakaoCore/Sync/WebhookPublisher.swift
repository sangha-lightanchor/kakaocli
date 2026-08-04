import Foundation

/// Posts new messages to a webhook URL as JSON.
public final class WebhookPublisher: @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private let redirectDelegate: WebhookRedirectDelegate

    public init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let redirectDelegate = WebhookRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: config,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    /// Remote webhook traffic must be encrypted. Plain HTTP is accepted only
    /// for an explicitly configured loopback development endpoint.
    public static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    /// POST a batch of messages to the webhook. Returns true on 2xx response.
    public func publish(_ messages: [SyncMessage]) -> Bool {
        guard Self.isAllowedEndpoint(url) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(messages) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("kakaocli/0.7.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        nonisolated(unsafe) var success = false
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                success = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return success
    }
}

final class WebhookRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static func validatedRedirect(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url,
              WebhookPublisher.isAllowedEndpoint(url) else { return nil }
        return request
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.validatedRedirect(request))
    }
}
