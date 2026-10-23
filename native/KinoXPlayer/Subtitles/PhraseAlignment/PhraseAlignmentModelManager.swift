import Combine
import CoreML
import Foundation

protocol PhraseAlignmentModelCompiling: Sendable {
    func compileModel(at packageURL: URL, to destinationURL: URL) async throws
}

struct CoreMLPhraseAlignmentModelCompiler: PhraseAlignmentModelCompiling {
    func compileModel(at packageURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let compiledURL = try MLModel.compileModel(at: packageURL)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: compiledURL, to: destinationURL)
        }.value
    }
}

@MainActor
final class PhraseAlignmentModelManager: ObservableObject {
    typealias EmbeddingProviderLoader = @Sendable (
        _ compiledModelURL: URL,
        _ tokenizerDirectoryURL: URL
    ) async throws -> any PhraseEmbeddingProviding
    typealias PreActivationHook = @Sendable () async -> Void

    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case compiling
        case ready
        case failed(message: String)
    }

    static let shared = PhraseAlignmentModelManager()
    static let downloadByteCount = PhraseAlignmentModelManifest.totalDownloadByteCount

    @Published private(set) var state: State

    var isReady: Bool {
        state == .ready
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let transport: any PhraseAlignmentModelTransport
    private let compiler: any PhraseAlignmentModelCompiling
    private let embeddingProviderLoader: EmbeddingProviderLoader
    private let installationAssets: [PhraseAlignmentModelAsset]
    private let installationDownloadByteCount: Int64
    private let preActivationHook: PreActivationHook
    private let startupError: Error?

    private var installationID: UUID?
    private var installationTask: Task<Void, Never>?
    private var removalTask: Task<Void, Never>?
    private var embeddingProvider: (any PhraseEmbeddingProviding)?
    private var embeddingProviderLoadTask: Task<any PhraseEmbeddingProviding, Error>?
    private var modelGeneration = UUID()

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        transport: any PhraseAlignmentModelTransport = PhraseAlignmentURLSessionTransport(),
        compiler: any PhraseAlignmentModelCompiling = CoreMLPhraseAlignmentModelCompiler(),
        embeddingProviderLoader: @escaping EmbeddingProviderLoader = {
            compiledModelURL,
            tokenizerDirectoryURL in
            try await CoreMLPhraseEmbeddingProvider.load(
                compiledModelURL: compiledModelURL,
                tokenizerDirectoryURL: tokenizerDirectoryURL
            )
        },
        installationAssets: [PhraseAlignmentModelAsset] = PhraseAlignmentModelManifest.assets,
        preActivationHook: @escaping PreActivationHook = {}
    ) {
        self.fileManager = fileManager
        self.transport = transport
        self.compiler = compiler
        self.embeddingProviderLoader = embeddingProviderLoader
        self.installationAssets = installationAssets
        self.installationDownloadByteCount = installationAssets.reduce(0) {
            $0 + max($1.byteCount, 0)
        }
        self.preActivationHook = preActivationHook

        do {
            let resolvedRootURL = try rootURL ?? Self.defaultRootURL(fileManager: fileManager)
            try Self.recoverInstallationOnStartup(
                at: resolvedRootURL,
                fileManager: fileManager
            )
            self.rootURL = resolvedRootURL
            startupError = nil
            state = Self.isValidInstallation(
                at: resolvedRootURL.appendingPathComponent("active", isDirectory: true),
                fileManager: fileManager
            ) ? .ready : .notInstalled
        } catch {
            self.rootURL = fileManager.temporaryDirectory
                .appendingPathComponent("KinoXPlayer-UnavailableModels", isDirectory: true)
            startupError = error
            state = .failed(message: error.localizedDescription)
        }
    }

    deinit {
        installationTask?.cancel()
        removalTask?.cancel()
        embeddingProviderLoadTask?.cancel()
    }

    func install() {
        guard installationTask == nil, !isReady else { return }
        guard startupError == nil else {
            state = .failed(
                message: startupError?.localizedDescription
                    ?? PhraseAlignmentModelError.storageUnavailable.localizedDescription
            )
            return
        }

        invalidateEmbeddingProviderLoad()
        let identifier = UUID()
        installationID = identifier
        state = .downloading(progress: 0)
        installationTask = Task { [weak self] in
            await self?.performInstallation(identifier: identifier)
        }
    }

    func cancelInstallation() {
        installationID = nil
        installationTask?.cancel()
        installationTask = nil
        state = Self.isValidInstallation(at: activeURL, fileManager: fileManager)
            ? .ready
            : .notInstalled
    }

    func removeModel() {
        cancelInstallation()
        invalidateEmbeddingProviderLoad()
        state = .notInstalled

        removalTask?.cancel()
        let rootURL = rootURL
        removalTask = Task {
            await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: rootURL.path) {
                    try? fileManager.removeItem(at: rootURL)
                }
            }.value
        }
    }

    func makeEmbeddingProvider() async throws -> any PhraseEmbeddingProviding {
        try Task.checkCancellation()
        guard isReady,
              Self.isValidInstallation(at: activeURL, fileManager: fileManager) else {
            state = .notInstalled
            throw PhraseAlignmentModelError.modelNotInstalled
        }
        if let embeddingProvider {
            return embeddingProvider
        }

        let generation = modelGeneration
        let loadTask: Task<any PhraseEmbeddingProviding, Error>
        if let embeddingProviderLoadTask {
            loadTask = embeddingProviderLoadTask
        } else {
            let compiledModelURL = activeURL.appendingPathComponent(
                PhraseAlignmentModelManifest.compiledModelRelativePath,
                isDirectory: true
            )
            let tokenizerDirectoryURL = activeURL.appendingPathComponent(
                PhraseAlignmentModelManifest.tokenizerRelativePath,
                isDirectory: true
            )
            let loader = embeddingProviderLoader
            loadTask = Task.detached(priority: .utility) {
                try await loader(compiledModelURL, tokenizerDirectoryURL)
            }
            embeddingProviderLoadTask = loadTask
        }

        do {
            let provider = try await loadTask.value
            guard modelGeneration == generation, isReady else {
                throw PhraseAlignmentModelError.modelNotInstalled
            }
            embeddingProvider = provider
            embeddingProviderLoadTask = nil
            try Task.checkCancellation()
            return provider
        } catch is CancellationError {
            if modelGeneration == generation, isReady {
                embeddingProviderLoadTask = nil
            }
            throw CancellationError()
        } catch {
            guard modelGeneration == generation, isReady else {
                throw error
            }
            embeddingProviderLoadTask = nil
            state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    private func invalidateEmbeddingProviderLoad() {
        modelGeneration = UUID()
        embeddingProviderLoadTask?.cancel()
        embeddingProviderLoadTask = nil
        embeddingProvider = nil
    }

    private var activeURL: URL {
        rootURL.appendingPathComponent("active", isDirectory: true)
    }

    private func performInstallation(identifier: UUID) async {
        let stagingURL = rootURL.appendingPathComponent(
            ".staging-\(identifier.uuidString)",
            isDirectory: true
        )

        do {
            if let removalTask {
                await removalTask.value
            }
            try ensureCurrentInstallation(identifier)
            try await Self.prepareStagingDirectory(at: stagingURL, rootURL: rootURL)
            try ensureCurrentInstallation(identifier)

            var completedByteCount = Int64(0)
            for asset in installationAssets {
                try ensureCurrentInstallation(identifier)
                let destinationURL = stagingURL.appendingPathComponent(
                    asset.relativePath,
                    isDirectory: false
                )
                try await Self.prepareParentDirectory(for: destinationURL)
                let partialURL = destinationURL.appendingPathExtension("partial")
                let request = URLRequest(
                    url: asset.remoteURL,
                    cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                    timeoutInterval: 60
                )
                let bytesBeforeAsset = completedByteCount

                try await transport.download(
                    request,
                    to: partialURL,
                    expectedByteCount: asset.byteCount
                ) { [weak self] downloadedByteCount in
                    Task { @MainActor [weak self] in
                        self?.receiveProgress(
                            identifier: identifier,
                            completedByteCount: bytesBeforeAsset,
                            currentFileByteCount: downloadedByteCount
                        )
                    }
                }
                try ensureCurrentInstallation(identifier)
                try await Self.verify(asset: asset, at: partialURL)
                try ensureCurrentInstallation(identifier)
                try await Self.finishDownloadedFile(from: partialURL, to: destinationURL)
                try ensureCurrentInstallation(identifier)
                completedByteCount += asset.byteCount
                receiveProgress(
                    identifier: identifier,
                    completedByteCount: completedByteCount,
                    currentFileByteCount: 0
                )
            }

            try ensureCurrentInstallation(identifier)
            try await Self.prepareRuntimeTokenizerConfiguration(in: stagingURL)
            try ensureCurrentInstallation(identifier)
            state = .compiling
            let packageURL = stagingURL.appendingPathComponent(
                PhraseAlignmentModelManifest.modelPackageRelativePath,
                isDirectory: true
            )
            let compiledURL = stagingURL.appendingPathComponent(
                PhraseAlignmentModelManifest.compiledModelRelativePath,
                isDirectory: true
            )
            try await compiler.compileModel(at: packageURL, to: compiledURL)
            try ensureCurrentInstallation(identifier)
            try await Self.removeSourceModelPackage(at: packageURL)
            try ensureCurrentInstallation(identifier)
            try await Self.writeReceipt(to: stagingURL)
            try ensureCurrentInstallation(identifier)
            await preActivationHook()
            try ensureCurrentInstallation(identifier)

            // Cancellation and activation are serialized on the main actor. The
            // commit itself only renames directories on one volume, so Cancel
            // either wins before this point or observes a fully ready model.
            let backupURL = try Self.activateCommit(
                stagingURL: stagingURL,
                activeURL: activeURL
            )

            invalidateEmbeddingProviderLoad()
            state = .ready
            installationID = nil
            installationTask = nil
            if let backupURL {
                Self.removeCommittedBackupLater(at: backupURL)
            }
        } catch is CancellationError {
            await Self.removeItemIfPresent(at: stagingURL)
            if installationID == identifier {
                installationID = nil
                installationTask = nil
                state = Self.isValidInstallation(at: activeURL, fileManager: fileManager)
                    ? .ready
                    : .notInstalled
            }
        } catch {
            await Self.removeItemIfPresent(at: stagingURL)
            if installationID == identifier {
                installationID = nil
                installationTask = nil
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    private func ensureCurrentInstallation(_ identifier: UUID) throws {
        guard installationID == identifier, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func receiveProgress(
        identifier: UUID,
        completedByteCount: Int64,
        currentFileByteCount: Int64
    ) {
        guard installationID == identifier else { return }
        let downloaded = min(
            installationDownloadByteCount,
            completedByteCount + max(0, currentFileByteCount)
        )
        let progress = installationDownloadByteCount > 0
            ? Double(downloaded) / Double(installationDownloadByteCount)
            : 1
        state = .downloading(progress: min(1, max(0, progress)))
    }

    private static func defaultRootURL(fileManager: FileManager) throws -> URL {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PhraseAlignmentModelError.storageUnavailable
        }
        return applicationSupportURL
            .appendingPathComponent("KinoXPlayer", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("PhraseAlignment", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private enum RecoveryCandidateKind: Equatable {
        case backup
        case staging
    }

    private struct RecoveryCandidate {
        let url: URL
        let kind: RecoveryCandidateKind
        let isValid: Bool
        let installedAt: Date
        let canRemoveSafely: Bool
    }

    /// Repairs the two crash windows in model activation before the manager
    /// publishes its initial state:
    ///
    /// 1. `active` was moved to a backup, but staging was not activated yet;
    /// 2. a fully prepared staging directory was left just before activation.
    ///
    /// Only direct children bearing the exact names emitted by this manager are
    /// considered. Symbolic links are never treated as recoverable installations.
    private static func recoverInstallationOnStartup(
        at rootURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }

        let rootValues = try rootURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw PhraseAlignmentModelError.storageUnavailable
        }

        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsSubdirectoryDescendants]
        )
        let candidates: [RecoveryCandidate] = children.compactMap { url in
            guard url.deletingLastPathComponent().standardizedFileURL
                    == rootURL.standardizedFileURL,
                  let kind = recoveryCandidateKind(for: url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                  ]) else {
                return nil
            }

            let isSymbolicLink = values.isSymbolicLink == true
            let isSafeDirectory = values.isDirectory == true && !isSymbolicLink
            let isValid = isSafeDirectory
                && isValidInstallation(at: url, fileManager: fileManager)
            return RecoveryCandidate(
                url: url,
                kind: kind,
                isValid: isValid,
                installedAt: isValid
                    ? installationDate(at: url, fileManager: fileManager)
                    : .distantPast,
                canRemoveSafely: isSafeDirectory || isSymbolicLink
            )
        }

        let activeURL = rootURL.appendingPathComponent("active", isDirectory: true)
        var activeIsValid = isValidInstallation(at: activeURL, fileManager: fileManager)
        if !activeIsValid {
            removeDirectRecoveryItemIfSafe(
                at: activeURL,
                rootURL: rootURL,
                fileManager: fileManager
            )

            let validBackups = sortedRecoveryCandidates(
                candidates.filter { $0.kind == .backup && $0.isValid }
            )
            let validStaging = sortedRecoveryCandidates(
                candidates.filter { $0.kind == .staging && $0.isValid }
            )
            for candidate in validBackups + validStaging {
                if fileManager.fileExists(atPath: activeURL.path) {
                    if isValidInstallation(at: activeURL, fileManager: fileManager) {
                        activeIsValid = true
                        break
                    }
                    removeDirectRecoveryItemIfSafe(
                        at: activeURL,
                        rootURL: rootURL,
                        fileManager: fileManager
                    )
                }
                guard !fileManager.fileExists(atPath: activeURL.path) else {
                    continue
                }

                do {
                    try fileManager.moveItem(at: candidate.url, to: activeURL)
                    if isValidInstallation(at: activeURL, fileManager: fileManager) {
                        activeIsValid = true
                        break
                    }
                    removeDirectRecoveryItemIfSafe(
                        at: activeURL,
                        rootURL: rootURL,
                        fileManager: fileManager
                    )
                } catch {
                    // Preserve a valid candidate when recovery fails because of a
                    // transient filesystem error so the next launch can retry it.
                    continue
                }
            }
        }

        for candidate in candidates {
            guard candidate.canRemoveSafely else { continue }
            if activeIsValid || !candidate.isValid {
                try? fileManager.removeItem(at: candidate.url)
            }
        }
    }

    private static func recoveryCandidateKind(
        for name: String
    ) -> RecoveryCandidateKind? {
        let prefixes: [(String, RecoveryCandidateKind)] = [
            (".backup-", .backup),
            (".staging-", .staging),
        ]
        for (prefix, kind) in prefixes where name.hasPrefix(prefix) {
            let identifier = String(name.dropFirst(prefix.count))
            guard identifier.count == 36,
                  let uuid = UUID(uuidString: identifier),
                  uuid.uuidString.caseInsensitiveCompare(identifier) == .orderedSame else {
                return nil
            }
            return kind
        }
        return nil
    }

    private static func sortedRecoveryCandidates(
        _ candidates: [RecoveryCandidate]
    ) -> [RecoveryCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.installedAt == rhs.installedAt {
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            return lhs.installedAt > rhs.installedAt
        }
    }

    private static func installationDate(
        at installationURL: URL,
        fileManager: FileManager
    ) -> Date {
        let receiptURL = installationURL.appendingPathComponent(
            PhraseAlignmentModelManifest.receiptFileName,
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: receiptURL.path),
              let data = try? Data(contentsOf: receiptURL) else {
            return .distantPast
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(
            PhraseAlignmentModelInstallationReceipt.self,
            from: data
        ))?.installedAt ?? .distantPast
    }

    private static func removeDirectRecoveryItemIfSafe(
        at url: URL,
        rootURL: URL,
        fileManager: FileManager
    ) {
        guard url.deletingLastPathComponent().standardizedFileURL
                == rootURL.standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
              ]),
              values.isDirectory == true
                || values.isRegularFile == true
                || values.isSymbolicLink == true else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    private static func prepareStagingDirectory(at stagingURL: URL, rootURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
            try fileManager.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }.value
    }

    private static func prepareParentDirectory(for fileURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }.value
    }

    private static func verify(asset: PhraseAlignmentModelAsset, at fileURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try PhraseAlignmentModelFileVerifier.verify(asset: asset, at: fileURL)
        }.value
    }

    private static func finishDownloadedFile(from partialURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: partialURL, to: destinationURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
        }.value
    }

    private static func writeReceipt(to stagingURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let receipt = PhraseAlignmentModelInstallationReceipt.current()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(receipt)
            let receiptURL = stagingURL.appendingPathComponent(
                PhraseAlignmentModelManifest.receiptFileName,
                isDirectory: false
            )
            try data.write(to: receiptURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: receiptURL.path
            )
        }.value
    }

    private static func prepareRuntimeTokenizerConfiguration(in stagingURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let sourceURL = stagingURL.appendingPathComponent(
                PhraseAlignmentModelManifest.sourceTokenizerConfigRelativePath,
                isDirectory: false
            )
            let destinationURL = stagingURL.appendingPathComponent(
                PhraseAlignmentModelManifest.runtimeTokenizerConfigRelativePath,
                isDirectory: false
            )
            let sourceData = try Data(contentsOf: sourceURL)
            guard var dictionary = try JSONSerialization.jsonObject(with: sourceData)
                as? [String: Any] else {
                throw PhraseAlignmentModelError.incompleteInstallation
            }
            dictionary["tokenizer_class"] =
                PhraseAlignmentModelManifest.compatibleUnigramTokenizerClass
            let runtimeData = try JSONSerialization.data(
                withJSONObject: dictionary,
                options: [.sortedKeys]
            )
            try runtimeData.write(to: destinationURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
        }.value
    }

    private static func removeSourceModelPackage(at packageURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: packageURL.path) else {
                throw PhraseAlignmentModelError.incompleteInstallation
            }
            try fileManager.removeItem(at: packageURL)
        }.value
    }

    private static func activateCommit(stagingURL: URL, activeURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        let backupURL = activeURL.deletingLastPathComponent().appendingPathComponent(
            ".backup-\(UUID().uuidString)",
            isDirectory: true
        )
        let hadActiveInstallation = fileManager.fileExists(atPath: activeURL.path)
        if hadActiveInstallation {
            try fileManager.moveItem(at: activeURL, to: backupURL)
        }

        do {
            try fileManager.moveItem(at: stagingURL, to: activeURL)
            return hadActiveInstallation ? backupURL : nil
        } catch {
            if hadActiveInstallation,
               !fileManager.fileExists(atPath: activeURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: activeURL)
            }
            throw error
        }
    }

    private static func removeCommittedBackupLater(at backupURL: URL) {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }
        }
    }

    private static func removeItemIfPresent(at url: URL) async {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }.value
    }

    private static func isValidInstallation(at activeURL: URL, fileManager: FileManager) -> Bool {
        guard let activeValues = try? activeURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]), activeValues.isDirectory == true,
           activeValues.isSymbolicLink != true else {
            return false
        }
        let receiptURL = activeURL.appendingPathComponent(
            PhraseAlignmentModelManifest.receiptFileName,
            isDirectory: false
        )
        guard let receiptData = try? Data(contentsOf: receiptURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let receipt = try? decoder.decode(
            PhraseAlignmentModelInstallationReceipt.self,
            from: receiptData
        ), receipt.matchesCurrentManifest else {
            return false
        }

        // The source mlpackage is removed after compilation so that the persistent
        // installation occupies about 245 MB instead of retaining a second copy
        // of the model weights. The receipt still records and pins every downloaded
        // asset; only tokenizer assets are expected to remain alongside mlmodelc.
        for asset in PhraseAlignmentModelManifest.assets where
            !asset.relativePath.hasPrefix(
                PhraseAlignmentModelManifest.modelPackageRelativePath + "/"
            ) {
            let fileURL = activeURL.appendingPathComponent(asset.relativePath, isDirectory: false)
            guard let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            ), values.isRegularFile == true,
               values.isSymbolicLink != true,
               Int64(values.fileSize ?? -1) == asset.byteCount else {
                return false
            }
        }

        let compiledModelURL = activeURL.appendingPathComponent(
            PhraseAlignmentModelManifest.compiledModelRelativePath,
            isDirectory: true
        )
        guard let compiledValues = try? compiledModelURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ), compiledValues.isDirectory == true,
           compiledValues.isSymbolicLink != true else {
            return false
        }

        let runtimeTokenizerConfigURL = activeURL.appendingPathComponent(
            PhraseAlignmentModelManifest.runtimeTokenizerConfigRelativePath,
            isDirectory: false
        )
        guard let runtimeTokenizerData = try? Data(contentsOf: runtimeTokenizerConfigURL),
              let runtimeTokenizerConfig = try? JSONSerialization.jsonObject(
                with: runtimeTokenizerData
              ) as? [String: Any],
              runtimeTokenizerConfig["tokenizer_class"] as? String
                == PhraseAlignmentModelManifest.compatibleUnigramTokenizerClass else {
            return false
        }
        return true
    }
}
