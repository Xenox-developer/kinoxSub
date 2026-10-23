import Foundation

struct OpenSubtitlesHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
}

enum OpenSubtitlesHostPolicy: Sendable {
    case api
    case subtitleDownload
}

protocol OpenSubtitlesHTTPTransport: Sendable {
    func send(
        _ request: URLRequest,
        maximumBytes: Int,
        hostPolicy: OpenSubtitlesHostPolicy
    ) async throws -> OpenSubtitlesHTTPResponse
}

final class OpenSubtitlesURLSessionTransport: NSObject, OpenSubtitlesHTTPTransport, @unchecked Sendable {
    static let maximumAPIPayloadBytes = 4 * 1_024 * 1_024
    static let maximumSubtitleBytes = 16 * 1_024 * 1_024

    private final class RequestState: @unchecked Sendable {
        var data = Data()
        var response: HTTPURLResponse?
        let maximumBytes: Int
        let hostPolicy: OpenSubtitlesHostPolicy
        let continuation: CheckedContinuation<OpenSubtitlesHTTPResponse, Error>

        init(
            maximumBytes: Int,
            hostPolicy: OpenSubtitlesHostPolicy,
            continuation: CheckedContinuation<OpenSubtitlesHTTPResponse, Error>
        ) {
            self.maximumBytes = maximumBytes
            self.hostPolicy = hostPolicy
            self.continuation = continuation
        }
    }

    private final class CancellationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var isCancelled = false

        func install(_ task: URLSessionTask) {
            lock.lock()
            if isCancelled {
                lock.unlock()
                task.cancel()
                return
            }
            self.task = task
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    private let lock = NSLock()
    private var states: [Int: RequestState] = [:]
    private var session: URLSession!

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func send(
        _ request: URLRequest,
        maximumBytes: Int,
        hostPolicy: OpenSubtitlesHostPolicy
    ) async throws -> OpenSubtitlesHTTPResponse {
        guard maximumBytes > 0,
              let url = request.url,
              Self.isAllowed(url, policy: hostPolicy) else {
            throw OpenSubtitlesError.unsafeURL
        }

        let cancellationBox = CancellationBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = RequestState(
                    maximumBytes: maximumBytes,
                    hostPolicy: hostPolicy,
                    continuation: continuation
                )

                lock.lock()
                states[task.taskIdentifier] = state
                lock.unlock()

                cancellationBox.install(task)
                task.resume()
            }
        } onCancel: {
            cancellationBox.cancel()
        }
    }

    static func isAllowed(_ url: URL) -> Bool {
        isAllowed(url, policy: .subtitleDownload)
    }

    static func isAllowed(_ url: URL, policy: OpenSubtitlesHostPolicy) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else {
            return false
        }

        let isAPIHost = host == "api.opensubtitles.com" || host == "vip-api.opensubtitles.com"
        if isAPIHost {
            return true
        }
        guard policy == .subtitleDownload else { return false }
        return host.hasSuffix(".opensubtitles.com") && host != ".opensubtitles.com"
    }

    private func finish(taskIdentifier: Int, result: Result<OpenSubtitlesHTTPResponse, Error>) {
        lock.lock()
        let state = states.removeValue(forKey: taskIdentifier)
        lock.unlock()
        state?.continuation.resume(with: result)
    }
}

extension OpenSubtitlesURLSessionTransport: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let hostPolicy = states[task.taskIdentifier]?.hostPolicy
        lock.unlock()
        guard let hostPolicy,
              let url = request.url,
              Self.isAllowed(url, policy: hostPolicy) else {
            finish(taskIdentifier: task.taskIdentifier, result: .failure(OpenSubtitlesError.unsafeURL))
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            finish(taskIdentifier: dataTask.taskIdentifier, result: .failure(OpenSubtitlesError.invalidPayload))
            completionHandler(.cancel)
            return
        }

        lock.lock()
        let state = states[dataTask.taskIdentifier]
        if let state {
            state.response = httpResponse
        }
        lock.unlock()

        guard let state else {
            completionHandler(.cancel)
            return
        }

        let expectedLength = httpResponse.expectedContentLength
        if expectedLength > Int64(state.maximumBytes) {
            finish(
                taskIdentifier: dataTask.taskIdentifier,
                result: .failure(OpenSubtitlesError.payloadTooLarge(maximumBytes: state.maximumBytes))
            )
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let state = states[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }

        if data.count > state.maximumBytes - state.data.count {
            states.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            state.continuation.resume(
                throwing: OpenSubtitlesError.payloadTooLarge(maximumBytes: state.maximumBytes)
            )
            dataTask.cancel()
            return
        }

        state.data.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard let state = states.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let error {
            state.continuation.resume(throwing: error)
            return
        }

        guard let response = state.response else {
            state.continuation.resume(throwing: OpenSubtitlesError.invalidPayload)
            return
        }

        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        state.continuation.resume(returning: OpenSubtitlesHTTPResponse(
            data: state.data,
            statusCode: response.statusCode,
            headers: headers
        ))
    }
}
