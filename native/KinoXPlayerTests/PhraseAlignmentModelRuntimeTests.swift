import CryptoKit
import Foundation
import XCTest
@testable import KinoXPlayer

final class PhraseAlignmentModelRuntimeTests: XCTestCase {
    func testPinnedManifestHasUniqueHTTPSAssetsAndExpectedSize() {
        XCTAssertEqual(
            PhraseAlignmentModelManifest.revision,
            "a39062b9112d981477eb4dcdc8b2e9f1a4b5a883"
        )
        XCTAssertEqual(PhraseAlignmentModelManifest.assets.count, 6)
        XCTAssertEqual(PhraseAlignmentModelManifest.totalDownloadByteCount, 244_574_214)
        XCTAssertEqual(
            Set(PhraseAlignmentModelManifest.assets.map(\.relativePath)).count,
            PhraseAlignmentModelManifest.assets.count
        )
        for asset in PhraseAlignmentModelManifest.assets {
            XCTAssertEqual(asset.remoteURL.scheme, "https")
            XCTAssertEqual(asset.remoteURL.host, "huggingface.co")
            XCTAssertGreaterThan(asset.byteCount, 0)
            XCTAssertEqual(asset.sha256.count, 64)
        }
    }

    func testFileVerifierAcceptsExactSizeAndSHA256() throws {
        let directoryURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appendingPathComponent("hello.bin")
        try Data("hello".utf8).write(to: fileURL)
        let asset = PhraseAlignmentModelAsset(
            remotePath: "hello.bin",
            relativePath: "hello.bin",
            byteCount: 5,
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )

        XCTAssertNoThrow(
            try PhraseAlignmentModelFileVerifier.verify(asset: asset, at: fileURL)
        )
    }

    func testFileVerifierRejectsWrongHashAndWrongSize() throws {
        let directoryURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appendingPathComponent("hello.bin")
        try Data("hello".utf8).write(to: fileURL)

        let wrongHash = PhraseAlignmentModelAsset(
            remotePath: "hello.bin",
            relativePath: "hello.bin",
            byteCount: 5,
            sha256: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(
            try PhraseAlignmentModelFileVerifier.verify(asset: wrongHash, at: fileURL)
        ) { error in
            XCTAssertEqual(
                error as? PhraseAlignmentModelError,
                .invalidFileHash(path: "hello.bin")
            )
        }

        let wrongSize = PhraseAlignmentModelAsset(
            remotePath: "hello.bin",
            relativePath: "hello.bin",
            byteCount: 6,
            sha256: wrongHash.sha256
        )
        XCTAssertThrowsError(
            try PhraseAlignmentModelFileVerifier.verify(asset: wrongSize, at: fileURL)
        ) { error in
            XCTAssertEqual(
                error as? PhraseAlignmentModelError,
                .invalidFileSize(path: "hello.bin", expected: 6, actual: 5)
            )
        }
    }

    func testURLSessionTransportWritesValidatedFileAndReportsProgress() async throws {
        ModelDownloadURLProtocol.configure(data: Data("hello".utf8), statusCode: 200)
        defer { ModelDownloadURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let transport = PhraseAlignmentURLSessionTransport(configuration: configuration)
        let directoryURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let destinationURL = directoryURL.appendingPathComponent("download.bin")
        let recorder = ProgressRecorder()

        try await transport.download(
            URLRequest(url: URL(string: "https://huggingface.co/test/hello.bin")!),
            to: destinationURL,
            expectedByteCount: 5
        ) { byteCount in
            recorder.record(byteCount)
        }

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("hello".utf8))
        XCTAssertEqual(recorder.lastValue, 5)
    }

    @MainActor
    func testManagerMovesToFailedWhenInjectedTransportFails() async {
        let rootURL = makeTemporaryDirectory().appendingPathComponent("models", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent()) }
        let manager = PhraseAlignmentModelManager(
            rootURL: rootURL,
            transport: FailingModelTransport()
        )

        manager.install()
        let finalState = await waitForState(manager) { state in
            if case .failed = state { return true }
            return false
        }

        guard case let .failed(message) = finalState else {
            return XCTFail("Expected failed state, received \(finalState)")
        }
        XCTAssertTrue(message.contains("тестовая ошибка загрузки"))
    }

    @MainActor
    func testManagerCancellationReturnsToNotInstalled() async {
        let rootURL = makeTemporaryDirectory().appendingPathComponent("models", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent()) }
        let manager = PhraseAlignmentModelManager(
            rootURL: rootURL,
            transport: SlowModelTransport()
        )

        manager.install()
        XCTAssertEqual(manager.state, .downloading(progress: 0))
        manager.cancelInstallation()
        XCTAssertEqual(manager.state, .notInstalled)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.state, .notInstalled)
    }

    @MainActor
    func testCancellationAtPreActivationNeverCommitsModel() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let packageManifest = Data("{}".utf8)
        let tokenizerConfiguration = Data(
            "{\"tokenizer_class\":\"T5Tokenizer\"}".utf8
        )
        let assets = [
            makeFixtureAsset(
                remotePath: "tests/package-manifest.json",
                relativePath: "Model.mlpackage/Manifest.json",
                data: packageManifest
            ),
            makeFixtureAsset(
                remotePath: "tests/tokenizer-config.json",
                relativePath: PhraseAlignmentModelManifest.sourceTokenizerConfigRelativePath,
                data: tokenizerConfiguration
            ),
        ]
        let fixtureData = Dictionary(uniqueKeysWithValues: [
            (assets[0].remoteURL.absoluteString, packageManifest),
            (assets[1].remoteURL.absoluteString, tokenizerConfiguration),
        ])
        let gate = LateInstallationGate()
        let manager = PhraseAlignmentModelManager(
            rootURL: rootURL,
            transport: FixtureModelTransport(dataByURL: fixtureData),
            compiler: FixtureModelCompiler(),
            installationAssets: assets,
            preActivationHook: {
                await gate.waitUntilReleased()
            }
        )

        manager.install()
        let reachedLatePhase = await waitForLateInstallationGate(gate)
        XCTAssertTrue(reachedLatePhase)
        manager.cancelInstallation()
        XCTAssertEqual(manager.state, .notInstalled)

        await gate.release()
        let cleanedStaging = await waitForStagingCleanup(in: rootURL)
        XCTAssertTrue(cleanedStaging)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("active", isDirectory: true).path
        ))
        XCTAssertEqual(manager.state, .notInstalled)
    }

    @MainActor
    func testProviderLoadIsCoalescedAndCancelledWaiterDoesNotFailModel() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makeValidInstallation(
            at: rootURL.appendingPathComponent("active", isDirectory: true),
            marker: "active"
        )
        let loader = ControlledEmbeddingProviderLoader()
        let manager = PhraseAlignmentModelManager(
            rootURL: rootURL,
            embeddingProviderLoader: { _, _ in
                try await loader.load()
            }
        )

        let first = Task { @MainActor in
            try await manager.makeEmbeddingProvider()
        }
        let second = Task { @MainActor in
            try await manager.makeEmbeddingProvider()
        }
        let initialLoadCount = await waitForLoaderCallCount(loader, atLeast: 1)
        XCTAssertEqual(initialLoadCount, 1)
        for _ in 0..<4 { await Task.yield() }

        first.cancel()
        await loader.succeedAll()

        do {
            _ = try await first.value
            XCTFail("A cancelled waiter must finish with CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let provider = try await second.value
        XCTAssertEqual(provider.modelVersion, RuntimeFakeEmbeddingProvider().modelVersion)
        let finalLoadCount = await loader.callCount
        XCTAssertEqual(finalLoadCount, 1)
        XCTAssertEqual(manager.state, .ready)
    }

    @MainActor
    func testStaleProviderFailureCannotOverwriteReinstallationState() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makeValidInstallation(
            at: rootURL.appendingPathComponent("active", isDirectory: true),
            marker: "active"
        )
        let loader = ControlledEmbeddingProviderLoader()
        let manager = PhraseAlignmentModelManager(
            rootURL: rootURL,
            transport: SlowModelTransport(),
            embeddingProviderLoader: { _, _ in
                try await loader.load()
            }
        )
        let staleRequest = Task { @MainActor in
            try await manager.makeEmbeddingProvider()
        }
        let initialLoadCount = await waitForLoaderCallCount(loader, atLeast: 1)
        XCTAssertEqual(initialLoadCount, 1)

        manager.removeModel()
        manager.install()
        XCTAssertEqual(manager.state, .downloading(progress: 0))
        await loader.failAll(with: ModelRuntimeTestError.providerLoad)

        do {
            _ = try await staleRequest.value
            XCTFail("The stale provider request must not succeed")
        } catch {
            // The request belongs to the removed model generation.
        }
        XCTAssertEqual(manager.state, .downloading(progress: 0))
        manager.removeModel()
    }

    @MainActor
    func testStartupKeepsValidActiveAndSweepsStrictCrashDirectories() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let activeURL = rootURL.appendingPathComponent("active", isDirectory: true)
        let backupURL = rootURL.appendingPathComponent(
            ".backup-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingURL = rootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let unrelatedURL = rootURL.appendingPathComponent(
            ".staging-not-a-uuid",
            isDirectory: true
        )
        try makeValidInstallation(at: activeURL, marker: "active")
        try makeValidInstallation(at: backupURL, marker: "backup")
        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unrelatedURL,
            withIntermediateDirectories: true
        )

        let manager = PhraseAlignmentModelManager(rootURL: rootURL)

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(try installationMarker(at: activeURL), "active")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    @MainActor
    func testStartupRestoresValidBackupBeforeNewerValidStaging() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let activeURL = rootURL.appendingPathComponent("active", isDirectory: true)
        let backupURL = rootURL.appendingPathComponent(
            ".backup-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingURL = rootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: activeURL,
            withIntermediateDirectories: true
        )
        try Data("incomplete".utf8).write(
            to: activeURL.appendingPathComponent("partial.bin")
        )
        try makeValidInstallation(
            at: backupURL,
            installedAt: Date(timeIntervalSince1970: 1_000),
            marker: "backup"
        )
        try makeValidInstallation(
            at: stagingURL,
            installedAt: Date(timeIntervalSince1970: 2_000),
            marker: "staging"
        )

        let manager = PhraseAlignmentModelManager(rootURL: rootURL)

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(try installationMarker(at: activeURL), "backup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @MainActor
    func testStartupRestoresStagingAndRejectsSymbolicLinkBackup() throws {
        let parentURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let rootURL = parentURL.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let activeURL = rootURL.appendingPathComponent("active", isDirectory: true)
        let stagingURL = rootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let invalidStagingURL = rootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let linkedBackupURL = rootURL.appendingPathComponent(
            ".backup-\(UUID().uuidString)",
            isDirectory: true
        )
        let outsideURL = parentURL.appendingPathComponent("outside", isDirectory: true)
        try makeValidInstallation(at: stagingURL, marker: "staging")
        try makeValidInstallation(at: outsideURL, marker: "outside")
        try FileManager.default.createDirectory(
            at: invalidStagingURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedBackupURL,
            withDestinationURL: outsideURL
        )

        let manager = PhraseAlignmentModelManager(rootURL: rootURL)

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(try installationMarker(at: activeURL), "staging")
        XCTAssertEqual(try installationMarker(at: outsideURL), "outside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkedBackupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidStagingURL.path))
    }

    @MainActor
    func testStartupRejectsSymbolicLinkModelRootWithoutTouchingTarget() throws {
        let parentURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let realRootURL = parentURL.appendingPathComponent("real-models", isDirectory: true)
        let linkedRootURL = parentURL.appendingPathComponent("linked-models", isDirectory: true)
        let activeURL = realRootURL.appendingPathComponent("active", isDirectory: true)
        try makeValidInstallation(at: activeURL, marker: "active")
        try FileManager.default.createSymbolicLink(
            at: linkedRootURL,
            withDestinationURL: realRootURL
        )

        let manager = PhraseAlignmentModelManager(rootURL: linkedRootURL)

        guard case .failed = manager.state else {
            return XCTFail("A symbolic-link model root must be rejected")
        }
        XCTAssertEqual(try installationMarker(at: activeURL), "active")
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinoXPlayer-PhraseModelTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func makeValidInstallation(
        at installationURL: URL,
        installedAt: Date = Date(timeIntervalSince1970: 1_000),
        marker: String
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: installationURL,
            withIntermediateDirectories: true
        )

        for asset in PhraseAlignmentModelManifest.assets where
            !asset.relativePath.hasPrefix(
                PhraseAlignmentModelManifest.modelPackageRelativePath + "/"
            ) {
            let fileURL = installationURL.appendingPathComponent(
                asset.relativePath,
                isDirectory: false
            )
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(fileManager.createFile(atPath: fileURL.path, contents: nil))
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: UInt64(asset.byteCount))
            try handle.close()
        }

        let compiledModelURL = installationURL.appendingPathComponent(
            PhraseAlignmentModelManifest.compiledModelRelativePath,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: compiledModelURL,
            withIntermediateDirectories: true
        )
        let runtimeTokenizerConfigURL = installationURL.appendingPathComponent(
            PhraseAlignmentModelManifest.runtimeTokenizerConfigRelativePath,
            isDirectory: false
        )
        let runtimeTokenizerData = try JSONSerialization.data(withJSONObject: [
            "tokenizer_class": PhraseAlignmentModelManifest.compatibleUnigramTokenizerClass,
        ])
        try runtimeTokenizerData.write(to: runtimeTokenizerConfigURL, options: .atomic)

        let receipt = PhraseAlignmentModelInstallationReceipt.current(
            installedAt: installedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let receiptURL = installationURL.appendingPathComponent(
            PhraseAlignmentModelManifest.receiptFileName,
            isDirectory: false
        )
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try Data(marker.utf8).write(
            to: installationURL.appendingPathComponent("recovery-marker.txt")
        )
    }

    private func installationMarker(at installationURL: URL) throws -> String {
        try String(
            contentsOf: installationURL.appendingPathComponent("recovery-marker.txt"),
            encoding: .utf8
        )
    }

    @MainActor
    private func waitForState(
        _ manager: PhraseAlignmentModelManager,
        timeout: TimeInterval = 2,
        predicate: (PhraseAlignmentModelManager.State) -> Bool
    ) async -> PhraseAlignmentModelManager.State {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(manager.state) {
                return manager.state
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return manager.state
    }

    private func waitForLoaderCallCount(
        _ loader: ControlledEmbeddingProviderLoader,
        atLeast expectedCount: Int,
        timeout: TimeInterval = 2
    ) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = await loader.callCount
            if count >= expectedCount { return count }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await loader.callCount
    }

    private func waitForLateInstallationGate(
        _ gate: LateInstallationGate,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await gate.wasReached { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await gate.wasReached
    }

    private func waitForStagingCleanup(
        in rootURL: URL,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil
            )) ?? []
            if !children.contains(where: { $0.lastPathComponent.hasPrefix(".staging-") }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func makeFixtureAsset(
        remotePath: String,
        relativePath: String,
        data: Data
    ) -> PhraseAlignmentModelAsset {
        PhraseAlignmentModelAsset(
            remotePath: remotePath,
            relativePath: relativePath,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }
}

private enum ModelRuntimeTestError: LocalizedError {
    case download
    case providerLoad

    var errorDescription: String? {
        switch self {
        case .download:
            return "тестовая ошибка загрузки"
        case .providerLoad:
            return "тестовая ошибка загрузки модели в память"
        }
    }
}

private struct RuntimeFakeEmbeddingProvider: PhraseEmbeddingProviding {
    let modelVersion = "runtime-fake-provider-v1"

    func embeddings(for texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}

private actor ControlledEmbeddingProviderLoader {
    private(set) var callCount = 0
    private var continuations: [
        CheckedContinuation<any PhraseEmbeddingProviding, Error>
    ] = []

    func load() async throws -> any PhraseEmbeddingProviding {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func succeedAll() {
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume(returning: RuntimeFakeEmbeddingProvider())
        }
    }

    func failAll(with error: Error) {
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: error)
        }
    }
}

private actor LateInstallationGate {
    private(set) var wasReached = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        wasReached = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct FixtureModelTransport: PhraseAlignmentModelTransport {
    let dataByURL: [String: Data]

    func download(
        _ request: URLRequest,
        to destinationURL: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let key = request.url?.absoluteString,
              let data = dataByURL[key],
              Int64(data.count) == expectedByteCount else {
            throw ModelRuntimeTestError.download
        }
        try data.write(to: destinationURL, options: .atomic)
        progress(Int64(data.count))
    }
}

private struct FixtureModelCompiler: PhraseAlignmentModelCompiling {
    func compileModel(at packageURL: URL, to destinationURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw ModelRuntimeTestError.providerLoad
        }
        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )
    }
}

private struct FailingModelTransport: PhraseAlignmentModelTransport {
    func download(
        _ request: URLRequest,
        to destinationURL: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        throw ModelRuntimeTestError.download
    }
}

private struct SlowModelTransport: PhraseAlignmentModelTransport {
    func download(
        _ request: URLRequest,
        to destinationURL: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    var lastValue: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }

    func record(_ value: Int64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

private final class ModelDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responseData = Data()
    private static var responseStatusCode = 200

    static func configure(data: Data, statusCode: Int) {
        lock.lock()
        responseData = data
        responseStatusCode = statusCode
        lock.unlock()
    }

    static func reset() {
        configure(data: Data(), statusCode: 200)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "huggingface.co"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let data = Self.responseData
        let statusCode = Self.responseStatusCode
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(data.count)"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
