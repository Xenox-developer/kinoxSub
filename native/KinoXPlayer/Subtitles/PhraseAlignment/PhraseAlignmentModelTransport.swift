import Foundation

protocol PhraseAlignmentModelTransport: Sendable {
    func download(
        _ request: URLRequest,
        to destinationURL: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws
}

enum PhraseAlignmentModelTransportError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case unexpectedContentLength(expected: Int64, actual: Int64)
    case missingDownloadedFile

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Сервер модели вернул некорректный ответ."
        case let .httpStatus(status):
            return "Сервер модели вернул ошибку HTTP \(status)."
        case let .unexpectedContentLength(expected, actual):
            return "Получен файл модели неверного размера (\(actual) вместо \(expected) байт)."
        case .missingDownloadedFile:
            return "Загруженный файл модели не найден."
        }
    }
}

final class PhraseAlignmentURLSessionTransport: NSObject,
    PhraseAlignmentModelTransport,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let baseConfiguration: URLSessionConfiguration

    private final class DownloadState: @unchecked Sendable {
        let destinationURL: URL
        let expectedByteCount: Int64
        let progress: @Sendable (Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
        var movedDownloadedFile = false
        var terminalError: Error?

        init(
            destinationURL: URL,
            expectedByteCount: Int64,
            progress: @escaping @Sendable (Int64) -> Void,
            continuation: CheckedContinuation<Void, Error>
        ) {
            self.destinationURL = destinationURL
            self.expectedByteCount = expectedByteCount
            self.progress = progress
            self.continuation = continuation
        }
    }

    private final class CancellableTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var isCancelled = false

        func setTask(_ task: URLSessionTask) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            self.task = task
            return !isCancelled
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
    private var states: [Int: DownloadState] = [:]
    private lazy var session: URLSession = {
        let configuration = (baseConfiguration.copy() as? URLSessionConfiguration)
            ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 30
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil

        let queue = OperationQueue()
        queue.name = "KinoXPlayer.PhraseAlignmentModelDownload"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    override convenience init() {
        self.init(configuration: .ephemeral)
    }

    init(configuration: URLSessionConfiguration) {
        baseConfiguration = configuration
        super.init()
    }

    func download(
        _ request: URLRequest,
        to destinationURL: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard request.url?.scheme?.lowercased() == "https" else {
            throw PhraseAlignmentModelTransportError.invalidResponse
        }

        let taskBox = CancellableTaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                let state = DownloadState(
                    destinationURL: destinationURL,
                    expectedByteCount: expectedByteCount,
                    progress: progress,
                    continuation: continuation
                )
                lock.lock()
                states[task.taskIdentifier] = state
                lock.unlock()

                if taskBox.setTask(task) {
                    task.resume()
                } else {
                    task.cancel()
                }
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Hugging Face may redirect large pinned assets to a CDN. Keep the
        // redirect, but never allow a TLS downgrade; hashes still authenticate
        // the exact bytes from the pinned model revision.
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
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
        lock.lock()
        guard let state = states[downloadTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        if totalBytesWritten > state.expectedByteCount {
            state.terminalError = PhraseAlignmentModelTransportError.unexpectedContentLength(
                expected: state.expectedByteCount,
                actual: totalBytesWritten
            )
            lock.unlock()
            downloadTask.cancel()
            return
        }
        let callback = state.progress
        lock.unlock()
        callback(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        guard let state = states[downloadTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw PhraseAlignmentModelTransportError.invalidResponse
            }
            guard response.statusCode == 200 else {
                throw PhraseAlignmentModelTransportError.httpStatus(response.statusCode)
            }
            let values = try location.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw PhraseAlignmentModelTransportError.missingDownloadedFile
            }
            let actualByteCount = Int64(values.fileSize ?? -1)
            guard actualByteCount == state.expectedByteCount else {
                throw PhraseAlignmentModelTransportError.unexpectedContentLength(
                    expected: state.expectedByteCount,
                    actual: actualByteCount
                )
            }

            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: state.destinationURL.path) {
                try fileManager.removeItem(at: state.destinationURL)
            }
            try fileManager.moveItem(at: location, to: state.destinationURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: state.destinationURL.path
            )

            lock.lock()
            state.movedDownloadedFile = true
            lock.unlock()
            state.progress(actualByteCount)
        } catch {
            lock.lock()
            state.terminalError = error
            lock.unlock()
        }
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
        let terminalError = state.terminalError
        let movedDownloadedFile = state.movedDownloadedFile
        lock.unlock()

        if let terminalError {
            state.continuation.resume(throwing: terminalError)
        } else if let urlError = error as? URLError, urlError.code == .cancelled {
            state.continuation.resume(throwing: CancellationError())
        } else if let error {
            state.continuation.resume(throwing: error)
        } else if movedDownloadedFile {
            state.continuation.resume()
        } else {
            state.continuation.resume(
                throwing: PhraseAlignmentModelTransportError.missingDownloadedFile
            )
        }
    }
}
