import Foundation

public protocol OpenSubtitlesServicing: Sendable {
    nonisolated func hasAPIKey() -> Bool
    nonisolated func storedAPIKey() throws -> String?
    func validateAndStoreAPIKey(_ key: String) async throws
    nonisolated func removeAPIKey() throws

    nonisolated func hasStoredSession() -> Bool
    func login(username: String, password: String) async throws
    func logout() async throws

    func search(videoURL: URL, query: String?, languages: [String]) async throws
        -> [OpenSubtitlesCandidate]
    func materialize(_ candidate: OpenSubtitlesCandidate) async throws
        -> MaterializedOpenSubtitle
    func materialize(fileID: Int, suggestedFileName: String?) async throws
        -> MaterializedOpenSubtitle
    func materialize(fileID: Int, suggestedFileName: String?, videoURL: URL) async throws
        -> MaterializedOpenSubtitle
}

public actor OpenSubtitlesService: OpenSubtitlesServicing {
    typealias FingerprintProvider = @Sendable (URL) async throws -> OpenSubtitlesMovieFingerprint

    private let credentials: any OpenSubtitlesCredentialStoring
    private let api: OpenSubtitlesAPIClient
    private let cache: OpenSubtitlesCache
    private let fingerprintProvider: FingerprintProvider
    private var inFlightDownloads: [Int: Task<MaterializedOpenSubtitle, Error>] = [:]

    public init(userAgent: String? = nil) throws {
        let credentials = KeychainOpenSubtitlesCredentialStore()
        let transport = OpenSubtitlesURLSessionTransport()
        let resolvedUserAgent = userAgent ?? Self.defaultUserAgent
        self.credentials = credentials
        self.api = OpenSubtitlesAPIClient(
            transport: transport,
            credentials: credentials,
            userAgent: resolvedUserAgent
        )
        self.cache = try OpenSubtitlesCache()
        self.fingerprintProvider = { url in
            try await Task.detached(priority: .userInitiated) {
                try OpenSubtitlesMovieHash.calculate(for: url)
            }.value
        }
    }

    init(
        transport: any OpenSubtitlesHTTPTransport,
        credentials: any OpenSubtitlesCredentialStoring,
        cacheRootURL: URL,
        userAgent: String = "KinoXPlayerTests v1.0",
        fingerprintProvider: @escaping FingerprintProvider = { url in
            try OpenSubtitlesMovieHash.calculate(for: url)
        }
    ) throws {
        self.credentials = credentials
        self.api = OpenSubtitlesAPIClient(
            transport: transport,
            credentials: credentials,
            userAgent: userAgent
        )
        self.cache = try OpenSubtitlesCache(rootURL: cacheRootURL)
        self.fingerprintProvider = fingerprintProvider
    }

    public nonisolated func hasAPIKey() -> Bool {
        guard let key = try? credentials.apiKey() else { return false }
        return !key.isEmpty
    }

    public nonisolated func storedAPIKey() throws -> String? {
        try credentials.apiKey()
    }

    public func validateAndStoreAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenSubtitlesError.invalidAPIKey }

        try await api.validateAPIKey(trimmed)
        let previousKey = try credentials.apiKey()
        try credentials.storeAPIKey(trimmed)
        if let previousKey, previousKey != trimmed {
            try credentials.removeSession()
        }
    }

    public nonisolated func removeAPIKey() throws {
        var firstError: Error?
        do {
            try credentials.removeAPIKey()
        } catch {
            firstError = error
        }
        do {
            try credentials.removeSession()
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    public nonisolated func hasStoredSession() -> Bool {
        guard (try? credentials.session()) != nil else { return false }
        return true
    }

    public func login(username: String, password: String) async throws {
        let session = try await api.login(username: username, password: password)
        try credentials.storeSession(session)
    }

    public func logout() async throws {
        // Revoke the remote bearer token when possible. Local logout must still
        // succeed offline or after the server has already expired the token.
        try? await api.logout()
        try credentials.removeSession()
    }

    public func search(
        videoURL: URL,
        query: String?,
        languages: [String]
    ) async throws -> [OpenSubtitlesCandidate] {
        guard hasAPIKey() else { throw OpenSubtitlesError.missingAPIKey }

        let normalizedLanguages = Self.normalizedLanguages(languages)
        guard !normalizedLanguages.isEmpty else { throw OpenSubtitlesError.invalidPayload }
        let normalizedQuery = query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(250)
        let queryValue = normalizedQuery
            .map(String.init)
            .map { $0.lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }

        let fingerprint: OpenSubtitlesMovieFingerprint?
        do {
            fingerprint = try await fingerprintProvider(videoURL)
        } catch {
            if queryValue == nil { throw Self.normalized(error) }
            fingerprint = nil
        }

        let records: (
            hash: [OpenSubtitlesAPIClient.SearchRecord],
            query: [OpenSubtitlesAPIClient.SearchRecord]
        )
        do {
            records = try await fetchSearchRecords(
                fingerprint: fingerprint,
                query: queryValue,
                languages: normalizedLanguages
            )
        } catch OpenSubtitlesError.unauthorized {
            // A stored JWT may have expired. Search itself does not require a
            // user session, so discard the stale token and retry once with the
            // application key on the public API host.
            try credentials.removeSession()
            records = try await fetchSearchRecords(
                fingerprint: fingerprint,
                query: queryValue,
                languages: normalizedLanguages
            )
        }

        let fromHash = Self.makeCandidates(records.hash, searchedByHash: true)
        let fromQuery = Self.makeCandidates(records.query, searchedByHash: false)
        return Self.mergedAndRanked(fromHash + fromQuery)
    }

    public func materialize(
        _ candidate: OpenSubtitlesCandidate
    ) async throws -> MaterializedOpenSubtitle {
        try await materialize(fileID: candidate.fileID, suggestedFileName: candidate.fileName)
    }

    public func materialize(
        fileID: Int,
        suggestedFileName: String? = nil
    ) async throws -> MaterializedOpenSubtitle {
        try await materialize(
            fileID: fileID,
            suggestedFileName: suggestedFileName,
            movieFolderName: nil
        )
    }

    public func materialize(
        fileID: Int,
        suggestedFileName: String? = nil,
        videoURL: URL
    ) async throws -> MaterializedOpenSubtitle {
        try await materialize(
            fileID: fileID,
            suggestedFileName: suggestedFileName,
            movieFolderName: OpenSubtitlesCache.movieFolderName(for: videoURL)
        )
    }

    private func materialize(
        fileID: Int,
        suggestedFileName: String?,
        movieFolderName: String?
    ) async throws -> MaterializedOpenSubtitle {
        guard fileID > 0 else { throw OpenSubtitlesError.invalidPayload }
        if let cached = try await cache.cachedArtifact(
            fileID: fileID,
            movieFolderName: movieFolderName
        ) {
            return cached
        }
        if let existing = inFlightDownloads[fileID] {
            _ = try await Self.value(of: existing)
            if let copied = try await cache.cachedArtifact(
                fileID: fileID,
                movieFolderName: movieFolderName
            ) {
                return copied
            }
            throw OpenSubtitlesError.cache(message: "не удалось скопировать файл в папку фильма")
        }

        // A provider filename is display-only. The cache path is derived solely from fileID.
        _ = suggestedFileName
        let task = Task { [api, cache] in
            let descriptor = try await api.downloadDescriptor(fileID: fileID)
            let data = try await api.downloadSubtitle(from: descriptor)
            let parsed: ParsedSubtitle
            do {
                parsed = try SubtitleParser.parse(data: data)
            } catch {
                throw OpenSubtitlesError.invalidPayload
            }
            guard !parsed.cues.isEmpty,
                  parsed.cues.count <= 100_000,
                  parsed.cues.allSatisfy({ cue in
                      cue.start.isFinite && cue.end.isFinite
                          && cue.start >= 0 && cue.end > cue.start
                          && cue.end <= 7 * 24 * 60 * 60
                  }) else {
                throw OpenSubtitlesError.invalidPayload
            }
            return try await cache.store(
                fileID: fileID,
                cues: parsed.cues,
                movieFolderName: movieFolderName
            )
        }
        inFlightDownloads[fileID] = task
        defer { inFlightDownloads[fileID] = nil }
        return try await Self.value(of: task)
    }

    private nonisolated static func value(
        of task: Task<MaterializedOpenSubtitle, Error>
    ) async throws -> MaterializedOpenSubtitle {
        do {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    static func mergedAndRanked(
        _ candidates: [OpenSubtitlesCandidate]
    ) -> [OpenSubtitlesCandidate] {
        var byFileID: [Int: OpenSubtitlesCandidate] = [:]
        for candidate in candidates where candidate.fileID > 0 {
            guard let existing = byFileID[candidate.fileID] else {
                byFileID[candidate.fileID] = candidate
                continue
            }
            if candidate.matchKind.rawValue > existing.matchKind.rawValue {
                byFileID[candidate.fileID] = candidate
            }
        }

        return byFileID.values.sorted { lhs, rhs in
            if lhs.matchKind != rhs.matchKind {
                return lhs.matchKind.rawValue > rhs.matchKind.rawValue
            }
            if (lhs.rating ?? -1) != (rhs.rating ?? -1) {
                return (lhs.rating ?? -1) > (rhs.rating ?? -1)
            }
            if (lhs.downloadCount ?? -1) != (rhs.downloadCount ?? -1) {
                return (lhs.downloadCount ?? -1) > (rhs.downloadCount ?? -1)
            }
            return lhs.fileID < rhs.fileID
        }
    }

    private static func makeCandidates(
        _ records: [OpenSubtitlesAPIClient.SearchRecord],
        searchedByHash: Bool
    ) -> [OpenSubtitlesCandidate] {
        records.flatMap { record in
            let matchKind: OpenSubtitlesMatchKind
            if record.movieHashMatch {
                matchKind = .exactHash
            } else {
                matchKind = searchedByHash ? .hash : .query
            }
            return record.files.map { file in
                OpenSubtitlesCandidate(
                    fileID: file.fileID,
                    subtitleID: record.subtitleID,
                    language: record.language,
                    fileName: file.fileName,
                    releaseName: record.releaseName,
                    featureTitle: record.featureTitle,
                    featureYear: record.featureYear,
                    framesPerSecond: record.framesPerSecond,
                    hearingImpaired: record.hearingImpaired,
                    forced: record.forced,
                    rating: record.rating,
                    downloadCount: record.downloadCount,
                    matchKind: matchKind
                )
            }
        }
    }

    private func fetchSearchRecords(
        fingerprint: OpenSubtitlesMovieFingerprint?,
        query: String?,
        languages: [String]
    ) async throws -> (
        hash: [OpenSubtitlesAPIClient.SearchRecord],
        query: [OpenSubtitlesAPIClient.SearchRecord]
    ) {
        if let fingerprint, let query {
            async let byHash = api.search(
                movieHash: fingerprint.movieHash,
                languages: languages
            )
            async let byQuery = api.search(
                query: query,
                languages: languages
            )
            return try await (byHash, byQuery)
        }
        if let fingerprint {
            return (
                try await api.search(
                    movieHash: fingerprint.movieHash,
                    languages: languages
                ),
                []
            )
        }
        if let query {
            return (
                [],
                try await api.search(query: query, languages: languages)
            )
        }
        throw OpenSubtitlesError.invalidVideo
    }

    private static func normalizedLanguages(_ languages: [String]) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return Array(Set(languages.compactMap { language -> String? in
            let value = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty,
                  value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
            return value
        })).sorted()
    }

    private static func normalized(_ error: Error) -> OpenSubtitlesError {
        if let error = error as? OpenSubtitlesError { return error }
        if error is CancellationError { return .cancelled }
        return .invalidVideo
    }

    private static var defaultUserAgent: String {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "KinoXPlayer"
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1.0"
        return "\(name) v\(version)"
    }
}
