import Foundation
import XCTest
@testable import KinoXPlayer

final class OpenSubtitlesServiceTests: XCTestCase {
    func testMovieHashUsesLittleEndianWordsAndWrappingSum() throws {
        var first = Data(repeating: 0, count: OpenSubtitlesMovieHash.chunkSize)
        var last = Data(repeating: 0, count: OpenSubtitlesMovieHash.chunkSize)
        first.replaceSubrange(0..<8, with: [1, 2, 3, 4, 5, 6, 7, 8])
        last.replaceSubrange(0..<8, with: [8, 7, 6, 5, 4, 3, 2, 1])

        let hash = try OpenSubtitlesMovieHash.hash(
            fileSize: 131_073,
            firstChunk: first,
            lastChunk: last
        )

        XCTAssertEqual(hash, "09090909090b090a")
    }

    func testSearchMergesHashAndQueryAndRanksExactMatchFirst() async throws {
        let credentials = MockCredentialStore(apiKey: "secret-api-key")
        let transport = MockTransport { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let names = Set(components?.queryItems?.map(\.name) ?? [])
            if names.contains("moviehash") {
                return Self.jsonResponse(Self.hashSearchJSON)
            }
            return Self.jsonResponse(Self.querySearchJSON)
        }
        let cacheURL = temporaryDirectory().appendingPathComponent("cache")
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: cacheURL,
            fingerprintProvider: { _ in
                OpenSubtitlesMovieFingerprint(movieHash: "0123456789abcdef", fileSize: 5_000_000)
            }
        )

        let candidates = try await service.search(
            videoURL: URL(fileURLWithPath: "/private/movie-name-must-not-leak.mkv"),
            query: "User supplied title",
            languages: ["ru", "de", "ru"]
        )

        XCTAssertEqual(candidates.map(\.fileID), [20, 10, 30])
        XCTAssertEqual(candidates.map(\.matchKind), [.exactHash, .hash, .query])
        XCTAssertEqual(candidates.first?.framesPerSecond, 23.976)

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Api-Key"), "secret-api-key")
            XCTAssertFalse(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty ?? true)
            let absoluteString = try XCTUnwrap(request.url?.absoluteString)
            XCTAssertFalse(absoluteString.contains("movie-name-must-not-leak"))
            XCTAssertFalse(absoluteString.contains("moviebytesize"))
            XCTAssertTrue(absoluteString.contains("languages=de,ru") || absoluteString.contains("languages=de%2Cru"))
        }
    }

    func testRateLimitMapsToTypedError() async throws {
        let credentials = MockCredentialStore(apiKey: "key")
        let transport = MockTransport { _ in
            return OpenSubtitlesHTTPResponse(
                data: Data(#"{"message":"too many requests"}"#.utf8),
                statusCode: 429,
                headers: ["retry-after": "12"]
            )
        }
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: temporaryDirectory(),
            fingerprintProvider: { _ in
                OpenSubtitlesMovieFingerprint(movieHash: "0123456789abcdef", fileSize: 1_000_000)
            }
        )

        do {
            _ = try await service.search(
                videoURL: URL(fileURLWithPath: "/private/video.mkv"),
                query: nil,
                languages: ["ru"]
            )
            XCTFail("Expected rate-limit error")
        } catch let error as OpenSubtitlesError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 12))
        }
    }

    func testSearchDropsExpiredSessionAndRetriesWithAPIKey() async throws {
        let credentials = MockCredentialStore(apiKey: "key")
        try credentials.storeSession(OpenSubtitlesStoredSession(
            token: "expired-token",
            baseURL: OpenSubtitlesAPIClient.publicBaseURL
        ))
        let transport = MockTransport { request in
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                return OpenSubtitlesHTTPResponse(
                    data: Data(#"{"message":"token expired"}"#.utf8),
                    statusCode: 401,
                    headers: [:]
                )
            }
            return Self.jsonResponse(#"{"data":[]}"#)
        }
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: temporaryDirectory(),
            fingerprintProvider: { _ in
                OpenSubtitlesMovieFingerprint(movieHash: "0123456789abcdef", fileSize: 1_000_000)
            }
        )

        let candidates = try await service.search(
            videoURL: URL(fileURLWithPath: "/private/video.mkv"),
            query: "film",
            languages: ["ru"]
        )

        XCTAssertTrue(candidates.isEmpty)
        XCTAssertNil(try credentials.session())
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.filter {
            $0.value(forHTTPHeaderField: "Authorization") != nil
        }.count, 2)
        XCTAssertEqual(requests.filter {
            $0.value(forHTTPHeaderField: "Authorization") == nil
        }.count, 2)
    }

    func testSearchSafelySkipsOutOfRangeNumericMetadata() async throws {
        let credentials = MockCredentialStore(apiKey: "key")
        let transport = MockTransport { _ in
            Self.jsonResponse(#"""
            {
              "data": [{
                "id": "oversized",
                "attributes": {
                  "language": "ru",
                  "download_count": 1e300,
                  "feature_details": { "year": 1e300 },
                  "files": [{ "file_id": 1e300, "file_name": "bad.srt" }]
                }
              }]
            }
            """#)
        }
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: temporaryDirectory(),
            fingerprintProvider: { _ in
                OpenSubtitlesMovieFingerprint(movieHash: "0123456789abcdef", fileSize: 1_000_000)
            }
        )

        let candidates = try await service.search(
            videoURL: URL(fileURLWithPath: "/private/video.mkv"),
            query: nil,
            languages: ["ru"]
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testValidationStoresKeyAndLoginStoresSessionWithoutPassword() async throws {
        let credentials = MockCredentialStore(apiKey: nil)
        let transport = MockTransport { request in
            switch request.url?.path {
            case "/api/v1/subtitles":
                return Self.jsonResponse(#"{"data":[]}"#)
            case "/api/v1/login":
                let body = try XCTUnwrap(request.httpBody)
                XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("one-time-password"))
                return Self.jsonResponse(
                    #"{"token":"jwt-token","base_url":"https://vip-api.opensubtitles.com/api/v1"}"#
                )
            default:
                return Self.jsonResponse(#"{"data":[]}"#)
            }
        }
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: temporaryDirectory()
        )

        XCTAssertFalse(service.hasAPIKey())
        try await service.validateAndStoreAPIKey("  valid-key  ")
        XCTAssertEqual(try service.storedAPIKey(), "valid-key")
        try await service.login(username: "person", password: "one-time-password")
        XCTAssertTrue(service.hasStoredSession())
        XCTAssertEqual(try credentials.session()?.token, "jwt-token")
        XCTAssertNil(credentials.persistedPassword)
    }

    func testRemovingAPIKeyAlsoClearsStoredSession() throws {
        let credentials = MockCredentialStore(apiKey: "key")
        try credentials.storeSession(OpenSubtitlesStoredSession(
            token: "old-token",
            baseURL: OpenSubtitlesAPIClient.publicBaseURL
        ))
        let service = try OpenSubtitlesService(
            transport: MockTransport { _ in Self.jsonResponse(#"{"data":[]}"#) },
            credentials: credentials,
            cacheRootURL: temporaryDirectory()
        )

        try service.removeAPIKey()

        XCTAssertNil(try credentials.apiKey())
        XCTAssertNil(try credentials.session())
        XCTAssertFalse(service.hasStoredSession())
    }

    func testValidationUsesProtectedSearchAndMapsForbiddenToInvalidKey() async throws {
        let credentials = MockCredentialStore(apiKey: nil)
        let transport = MockTransport { request in
            if request.url?.path == "/api/v1/infos/formats" {
                return Self.jsonResponse(#"{"data":{"output_formats":["srt"]}}"#)
            }
            return OpenSubtitlesHTTPResponse(
                data: Data(#"{"message":"invalid API key"}"#.utf8),
                statusCode: 403,
                headers: [:]
            )
        }
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: temporaryDirectory()
        )

        do {
            try await service.validateAndStoreAPIKey("bad-key")
            XCTFail("Expected invalid-key error")
        } catch let error as OpenSubtitlesError {
            XCTAssertEqual(error, .invalidAPIKey)
        }
        XCTAssertFalse(service.hasAPIKey())
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v1/subtitles"])
    }

    func testDownloadQuotaDoesNotAskUserToLogInAgain() async throws {
        let credentials = MockCredentialStore(apiKey: "key")
        try credentials.storeSession(OpenSubtitlesStoredSession(
            token: "valid-token",
            baseURL: OpenSubtitlesAPIClient.publicBaseURL
        ))
        let transport = MockTransport { _ in
            OpenSubtitlesHTTPResponse(
                data: Data(
                    #"{"message":"Download limit reached","reset_time_utc":"2026-08-10 00:00:00"}"#.utf8
                ),
                statusCode: 406,
                headers: [:]
            )
        }
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: temporaryDirectory()
        )

        do {
            _ = try await service.materialize(fileID: 88)
            XCTFail("Expected quota error")
        } catch let error as OpenSubtitlesError {
            XCTAssertEqual(
                error,
                .downloadLimitExceeded(resetTime: "2026-08-10 00:00:00")
            )
        }
        XCTAssertNotNil(try credentials.session())
    }

    func testLogoutRevokesRemoteSessionAndAlwaysClearsLocalSession() async throws {
        let credentials = MockCredentialStore(apiKey: "key")
        try credentials.storeSession(OpenSubtitlesStoredSession(
            token: "jwt-token",
            baseURL: OpenSubtitlesAPIClient.publicBaseURL
        ))
        let transport = MockTransport { request in
            XCTAssertEqual(request.url?.path, "/api/v1/logout")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-token")
            return OpenSubtitlesHTTPResponse(data: Data(), statusCode: 503, headers: [:])
        }
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: temporaryDirectory()
        )

        try await service.logout()

        XCTAssertNil(try credentials.session())
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testCancellingOnlyWaiterReturnsCancellation() async throws {
        let credentials = MockCredentialStore(apiKey: "key")
        let service = try OpenSubtitlesService(
            transport: SlowCancellationTransport(),
            credentials: credentials,
            cacheRootURL: temporaryDirectory()
        )
        let task = Task {
            try await service.materialize(fileID: 99)
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as OpenSubtitlesError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // Either typed cancellation path is acceptable to the UI layer.
        }
    }

    func testCancellingOneWaiterDoesNotCancelSharedMaterialization() async throws {
        let credentials = MockCredentialStore(apiKey: "key")
        let transport = SharedMaterializationTransport()
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: temporaryDirectory()
        )
        let first = Task { try await service.materialize(fileID: 123) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = Task { try await service.materialize(fileID: 123) }
        try await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()

        do {
            _ = try await first.value
            XCTFail("Expected the first waiter to observe cancellation")
        } catch is CancellationError {
            // The shared download remains alive for the second waiter.
        }
        let artifact = try await second.value

        XCTAssertEqual(artifact.cueCount, 1)
        let requestCounts = await transport.requestCounts()
        XCTAssertEqual(requestCounts.downloadDescriptor, 1)
        XCTAssertEqual(requestCounts.subtitleFile, 1)
    }

    func testMaterializeValidatesAndWritesCanonicalDeterministicCacheFile() async throws {
        let credentials = MockCredentialStore(apiKey: "key")
        let transport = MockTransport { request in
            if request.url?.path == "/api/v1/download" {
                let body = try XCTUnwrap(request.httpBody)
                let bodyString = String(decoding: body, as: UTF8.self)
                XCTAssertTrue(bodyString.contains("\"file_id\":77"))
                XCTAssertTrue(bodyString.contains("\"sub_format\":\"srt\""))
                return Self.jsonResponse(
                    #"{"link":"https://dl.opensubtitles.com/subtitles/77","file_name":"../../unsafe.srt"}"#
                )
            }
            return OpenSubtitlesHTTPResponse(
                data: Data("1\r\n00:00:01,000 --> 00:00:02,500\r\n<b>Hello</b>\r\n".utf8),
                statusCode: 200,
                headers: [:]
            )
        }
        let cacheURL = temporaryDirectory().appendingPathComponent("subtitles", isDirectory: true)
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: cacheURL
        )

        let artifact = try await service.materialize(fileID: 77, suggestedFileName: "../../unsafe.srt")

        XCTAssertEqual(artifact.fileURL.lastPathComponent, "opensubtitles-77.srt")
        XCTAssertEqual(artifact.cueCount, 1)
        XCTAssertEqual(artifact.encodingName, "UTF-8")
        let saved = try String(contentsOf: artifact.fileURL, encoding: .utf8)
        XCTAssertEqual(saved, "1\n00:00:01,000 --> 00:00:02,500\nHello\n")
    }

    func testUnsafeHostsAndCacheNamesAreRejectedOrDeterministic() throws {
        XCTAssertTrue(OpenSubtitlesURLSessionTransport.isAllowed(
            try XCTUnwrap(URL(string: "https://api.opensubtitles.com/api/v1/subtitles"))
        ))
        XCTAssertTrue(OpenSubtitlesURLSessionTransport.isAllowed(
            try XCTUnwrap(URL(string: "https://dl.opensubtitles.com/file/1"))
        ))
        XCTAssertFalse(OpenSubtitlesURLSessionTransport.isAllowed(
            try XCTUnwrap(URL(string: "https://api.opensubtitles.com.evil.example/file"))
        ))
        XCTAssertFalse(OpenSubtitlesURLSessionTransport.isAllowed(
            try XCTUnwrap(URL(string: "http://dl.opensubtitles.com/file/1"))
        ))
        XCTAssertFalse(OpenSubtitlesURLSessionTransport.isAllowed(
            try XCTUnwrap(URL(string: "https://dl.opensubtitles.com/file/1")),
            policy: .api
        ))
        XCTAssertEqual(OpenSubtitlesCache.fileName(for: 42), "opensubtitles-42.srt")
    }

    func testDownloadedSubtitleDirectoryUsesPersistentApplicationSupportLocation() throws {
        let directory = try OpenSubtitlesCache.defaultRootURL()

        XCTAssertTrue(
            directory.path.hasSuffix(
                "/Library/Application Support/KinoXPlayer/Downloaded Subtitles/v1"
            )
        )
    }

    func testLegacyCacheMigrationKeepsSourceAndCreatesCanonicalPersistentCopy() async throws {
        let parent = temporaryDirectory()
        let legacyRoot = parent.appendingPathComponent("legacy/Subtitles/v1", isDirectory: true)
        let persistentRoot = parent.appendingPathComponent(
            "Application Support/KinoXPlayer/Downloaded Subtitles/v1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )
        let legacyFile = legacyRoot.appendingPathComponent("opensubtitles-44.srt")
        try Data(
            "1\r\n00:00:01,000 --> 00:00:02,000\r\n<b>Сохранено</b>\r\n".utf8
        ).write(to: legacyFile)
        try Data("not subtitles".utf8).write(
            to: legacyRoot.appendingPathComponent("opensubtitles-45.srt")
        )
        try Data("ignored".utf8).write(
            to: legacyRoot.appendingPathComponent("untrusted-name.srt")
        )

        let migrated = try OpenSubtitlesCache.migrateLegacyFiles(
            from: legacyRoot,
            to: persistentRoot
        )

        XCTAssertEqual(migrated, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        let persistentFile = persistentRoot.appendingPathComponent("opensubtitles-44.srt")
        XCTAssertEqual(
            try String(contentsOf: persistentFile, encoding: .utf8),
            "1\n00:00:01,000 --> 00:00:02,000\nСохранено\n"
        )
        let permissions = try FileManager.default.attributesOfItem(
            atPath: persistentFile.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        let reopenedCache = try OpenSubtitlesCache(rootURL: persistentRoot)
        let reopenedArtifact = try await reopenedCache.cachedArtifact(fileID: 44)
        XCTAssertEqual(reopenedArtifact?.cueCount, 1)
        XCTAssertEqual(reopenedArtifact?.fileURL, persistentFile)
    }

    func testLegacyMigrationIgnoresSymbolicLinkRoot() throws {
        let parent = temporaryDirectory()
        let realLegacyRoot = parent.appendingPathComponent("real-legacy", isDirectory: true)
        let linkedLegacyRoot = parent.appendingPathComponent("linked-legacy", isDirectory: true)
        let persistentRoot = parent.appendingPathComponent("persistent/subtitles/v1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realLegacyRoot,
            withIntermediateDirectories: true
        )
        try Data("1\n00:00:01,000 --> 00:00:02,000\nUnsafe\n".utf8).write(
            to: realLegacyRoot.appendingPathComponent("opensubtitles-9.srt")
        )
        try FileManager.default.createSymbolicLink(
            at: linkedLegacyRoot,
            withDestinationURL: realLegacyRoot
        )

        XCTAssertEqual(
            try OpenSubtitlesCache.migrateLegacyFiles(
                from: linkedLegacyRoot,
                to: persistentRoot
            ),
            0
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: persistentRoot.appendingPathComponent("opensubtitles-9.srt").path
            )
        )
    }

    func testSubtitleCopyUsesSafeNameAndKeepsSourceFile() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("opensubtitles-77.srt")
        let destination = directory.appendingPathComponent("saved.srt")
        let contents = Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8)
        try contents.write(to: source)
        try Data("old copy".utf8).write(to: destination)

        XCTAssertEqual(
            SubtitleFileActions.safeSuggestedFileName("../../unsafe.ass", sourceURL: source),
            "unsafe.ass.srt"
        )
        XCTAssertEqual(
            SubtitleFileActions.safeSuggestedFileName(nil, sourceURL: source),
            "opensubtitles-77.srt"
        )

        try SubtitleFileActions.writeCopy(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), contents)
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    func testSubtitleCopySuggestionUsesSourceFormatAndFilesystemByteLimit() throws {
        let source = URL(fileURLWithPath: "/private/cache/canonical.srt")

        XCTAssertEqual(
            SubtitleFileActions.safeSuggestedFileName("Movie.2024.eng", sourceURL: source),
            "Movie.2024.eng.srt"
        )
        XCTAssertEqual(
            SubtitleFileActions.safeSuggestedFileName("wrong-format.vtt", sourceURL: source),
            "wrong-format.srt"
        )

        let longName = String(repeating: "😀", count: 180) + ".srt"
        let safeName = SubtitleFileActions.safeSuggestedFileName(longName, sourceURL: source)
        XCTAssertLessThanOrEqual(safeName.utf8.count, 240)
        XCTAssertTrue(safeName.hasSuffix(".srt"))
    }

    func testMovieFolderNameUsesVideoTitleAndIsFilesystemSafe() {
        XCTAssertEqual(
            OpenSubtitlesCache.movieFolderName(forVideoName: "Eternal Sunshine 2004"),
            "Eternal Sunshine 2004"
        )

        let unsafe = "  ..Film: Name\\Cut\u{202E}\n  "
        let sanitized = OpenSubtitlesCache.movieFolderName(forVideoName: unsafe)
        XCTAssertEqual(sanitized, "Film- Name-Cut")
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains("\\"))
        XCTAssertFalse(sanitized.contains(":"))
        XCTAssertFalse(sanitized.contains("\u{202E}"))
        XCTAssertFalse(sanitized.hasPrefix("."))

        let longUnicodeName = String(repeating: "🎬", count: 200)
        let shortened = OpenSubtitlesCache.movieFolderName(forVideoName: longUnicodeName)
        XCTAssertLessThanOrEqual(shortened.utf8.count, 180)
        XCTAssertFalse(shortened.isEmpty)
    }

    func testOnlineSubtitleIsStoredInsideCurrentMovieFolder() async throws {
        let credentials = MockCredentialStore(apiKey: "key")
        let transport = MockTransport { request in
            if request.url?.path == "/api/v1/download" {
                return Self.jsonResponse(
                    #"{"link":"https://dl.opensubtitles.com/subtitles/501","file_name":"movie.srt"}"#
                )
            }
            return OpenSubtitlesHTTPResponse(
                data: Data("1\n00:00:01,000 --> 00:00:02,000\nSaved by movie\n".utf8),
                statusCode: 200,
                headers: [:]
            )
        }
        let rootURL = temporaryDirectory().appendingPathComponent("library", isDirectory: true)
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: credentials,
            cacheRootURL: rootURL
        )
        let videoURL = URL(fileURLWithPath: "/Movies/Eternal Sunshine 2004.mp4")

        let artifact = try await service.materialize(
            fileID: 501,
            suggestedFileName: "remote-name.srt",
            videoURL: videoURL
        )

        XCTAssertEqual(
            artifact.fileURL,
            rootURL
                .appendingPathComponent(
                    OpenSubtitlesCache.movieFolderName(for: videoURL),
                    isDirectory: true
                )
                .appendingPathComponent("opensubtitles-501.srt")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.fileURL.path))
    }

    func testSameRemoteFileForDifferentMoviesReturnsEachMovieFolderURL() async throws {
        let transport = SharedMaterializationTransport()
        let rootURL = temporaryDirectory().appendingPathComponent("library", isDirectory: true)
        let service = try OpenSubtitlesService(
            transport: transport,
            credentials: MockCredentialStore(apiKey: "key"),
            cacheRootURL: rootURL
        )

        async let first = service.materialize(
            fileID: 123,
            suggestedFileName: "shared.srt",
            videoURL: URL(fileURLWithPath: "/Movies/First Film.mp4")
        )
        async let second = service.materialize(
            fileID: 123,
            suggestedFileName: "shared.srt",
            videoURL: URL(fileURLWithPath: "/Movies/Second Film.mp4")
        )
        let artifacts = try await [first, second]

        let folderNames = Set(
            artifacts.map { $0.fileURL.deletingLastPathComponent().lastPathComponent }
        )
        XCTAssertEqual(folderNames.count, 2)
        XCTAssertTrue(folderNames.allSatisfy { $0.hasPrefix("First Film — ") || $0.hasPrefix("Second Film — ") })
        let counts = await transport.requestCounts()
        XCTAssertEqual(counts.downloadDescriptor, 1)
        XCTAssertEqual(counts.subtitleFile, 1)
    }

    func testFlatArtifactIsCopiedIntoMovieFolderWithoutRemovingSource() async throws {
        let rootURL = temporaryDirectory().appendingPathComponent("library", isDirectory: true)
        let cache = try OpenSubtitlesCache(rootURL: rootURL)
        let cues = [SubtitleCue(start: 1, end: 2, text: "Legacy")]
        let flatArtifact = try await cache.store(fileID: 502, cues: cues)

        let promoted = try await cache.cachedArtifact(
            fileID: 502,
            movieFolderName: "Legacy Film"
        )

        XCTAssertEqual(promoted?.fileURL.deletingLastPathComponent().lastPathComponent, "Legacy Film")
        XCTAssertTrue(FileManager.default.fileExists(atPath: flatArtifact.fileURL.path))
        XCTAssertEqual(
            try promoted.map { try String(contentsOf: $0.fileURL, encoding: .utf8) },
            "1\n00:00:01,000 --> 00:00:02,000\nLegacy\n"
        )
    }

    func testDifferentVideosWithSameTitleUseDifferentReadableFolders() {
        let first = URL(fileURLWithPath: "/Movies/Edition A/Movie.mp4")
        let second = URL(fileURLWithPath: "/Movies/Edition B/Movie.mp4")
        let firstName = OpenSubtitlesCache.movieFolderName(for: first)
        let secondName = OpenSubtitlesCache.movieFolderName(for: second)

        XCTAssertNotEqual(firstName, secondName)
        XCTAssertTrue(firstName.hasPrefix("Movie — "))
        XCTAssertTrue(secondName.hasPrefix("Movie — "))
        XCTAssertLessThanOrEqual(firstName.utf8.count, 180)
        XCTAssertLessThanOrEqual(secondName.utf8.count, 180)
    }

    func testNestedPersistentArtifactValidationRejectsDeepAndSymlinkFolders() throws {
        let rootURL = temporaryDirectory().appendingPathComponent("library", isDirectory: true)
        let videoURL = URL(fileURLWithPath: "/Movies/Safe Film.mp4")
        let movieFolder = try OpenSubtitlesCache.movieFolderURL(
            for: videoURL,
            rootURL: rootURL
        )
        let nestedFile = movieFolder.appendingPathComponent("opensubtitles-503.srt")
        try Data("subtitle".utf8).write(to: nestedFile)

        XCTAssertEqual(
            OpenSubtitlesCache.persistentArtifactLocation(
                for: nestedFile,
                rootURL: rootURL
            ),
            OpenSubtitlesPersistentArtifactLocation(
                fileID: 503,
                movieFolderName: movieFolder.lastPathComponent
            )
        )

        let deepFolder = movieFolder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: deepFolder, withIntermediateDirectories: false)
        let deepFile = deepFolder.appendingPathComponent("opensubtitles-503.srt")
        try Data("subtitle".utf8).write(to: deepFile)
        XCTAssertNil(
            OpenSubtitlesCache.persistentArtifactLocation(for: deepFile, rootURL: rootURL)
        )

        let outsideFolder = temporaryDirectory().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)
        let outsideFile = outsideFolder.appendingPathComponent("opensubtitles-504.srt")
        try Data("subtitle".utf8).write(to: outsideFile)
        let linkedFolder = rootURL.appendingPathComponent("Linked Film", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: outsideFolder)
        XCTAssertNil(
            OpenSubtitlesCache.persistentArtifactLocation(
                for: linkedFolder.appendingPathComponent("opensubtitles-504.srt"),
                rootURL: rootURL
            )
        )
    }

    func testCacheDoesNotDeleteDirectoryThatCollidesWithSubtitleFileName() async throws {
        let rootURL = temporaryDirectory().appendingPathComponent("library", isDirectory: true)
        let cache = try OpenSubtitlesCache(rootURL: rootURL)
        let movieFolder = try OpenSubtitlesCache.movieFolderURL(
            for: URL(fileURLWithPath: "/Movies/Collision.mp4"),
            rootURL: rootURL
        )
        let collision = movieFolder.appendingPathComponent(
            "opensubtitles-505.srt",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)

        let cached = try await cache.cachedArtifact(
            fileID: 505,
            movieFolderName: "Collision"
        )
        XCTAssertNil(cached)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: collision.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testLegacyMigrationDoesNotDeleteDirectoryCollision() throws {
        let parent = temporaryDirectory()
        let legacyRoot = parent.appendingPathComponent("legacy", isDirectory: true)
        let persistentRoot = parent.appendingPathComponent("persistent", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: persistentRoot, withIntermediateDirectories: true)
        try Data("1\n00:00:01,000 --> 00:00:02,000\nLegacy\n".utf8).write(
            to: legacyRoot.appendingPathComponent("opensubtitles-506.srt")
        )
        let collision = persistentRoot.appendingPathComponent(
            "opensubtitles-506.srt",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
        let sentinel = collision.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)

        XCTAssertEqual(
            try OpenSubtitlesCache.migrateLegacyFiles(
                from: legacyRoot,
                to: persistentRoot
            ),
            0
        )
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
    }

    func testCacheRefusesSymbolicLinkRoot() async throws {
        let parent = temporaryDirectory()
        let target = parent.appendingPathComponent("target", isDirectory: true)
        let symbolicRoot = parent.appendingPathComponent("linked-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symbolicRoot, withDestinationURL: target)
        let cache = try OpenSubtitlesCache(rootURL: symbolicRoot)

        do {
            _ = try await cache.store(
                fileID: 1,
                cues: [SubtitleCue(start: 1, end: 2, text: "Hello")]
            )
            XCTFail("Expected cache path rejection")
        } catch let error as OpenSubtitlesError {
            guard case .cache = error else {
                return XCTFail("Expected cache error, got \(error)")
            }
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KinoXPlayerTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func jsonResponse(_ json: String) -> OpenSubtitlesHTTPResponse {
        OpenSubtitlesHTTPResponse(data: Data(json.utf8), statusCode: 200, headers: [:])
    }

    private static let hashSearchJSON = #"""
    {
      "data": [
        {
          "id": "subtitle-exact",
          "attributes": {
            "language": "de",
            "ratings": "8.5",
            "download_count": "300",
            "fps": "23.976",
            "moviehash_match": 1,
            "files": [{"file_id": "20", "file_name": "exact.srt"}]
          }
        },
        {
          "id": 101,
          "attributes": {
            "language": "ru",
            "moviehash_match": false,
            "files": [{"file_id": 10, "file_name": "hash.srt"}]
          }
        }
      ]
    }
    """#

    private static let querySearchJSON = #"""
    {
      "data": [
        {
          "id": "duplicate",
          "attributes": {
            "language": "ru",
            "ratings": 10,
            "files": [{"file_id": 10, "file_name": "duplicate.srt"}]
          }
        },
        {
          "id": "query-only",
          "attributes": {
            "language": "ru",
            "ratings": 9,
            "files": [{"file_id": 30, "file_name": "query.srt"}, {"broken": true}]
          }
        },
        "malformed item that must be skipped"
      ]
    }
    """#
}

private actor MockTransport: OpenSubtitlesHTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> OpenSubtitlesHTTPResponse

    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(
        _ request: URLRequest,
        maximumBytes: Int,
        hostPolicy: OpenSubtitlesHostPolicy
    ) async throws -> OpenSubtitlesHTTPResponse {
        requests.append(request)
        let response = try handler(request)
        guard response.data.count <= maximumBytes else {
            throw OpenSubtitlesError.payloadTooLarge(maximumBytes: maximumBytes)
        }
        return response
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}

private struct SlowCancellationTransport: OpenSubtitlesHTTPTransport {
    func send(
        _ request: URLRequest,
        maximumBytes: Int,
        hostPolicy: OpenSubtitlesHostPolicy
    ) async throws -> OpenSubtitlesHTTPResponse {
        try await Task.sleep(nanoseconds: 100_000_000)
        return OpenSubtitlesHTTPResponse(data: Data(), statusCode: 500, headers: [:])
    }
}

private actor SharedMaterializationTransport: OpenSubtitlesHTTPTransport {
    private var descriptorRequestCount = 0
    private var subtitleRequestCount = 0

    func send(
        _ request: URLRequest,
        maximumBytes: Int,
        hostPolicy: OpenSubtitlesHostPolicy
    ) async throws -> OpenSubtitlesHTTPResponse {
        if request.url?.path == "/api/v1/download" {
            descriptorRequestCount += 1
            try await Task.sleep(nanoseconds: 120_000_000)
            return OpenSubtitlesHTTPResponse(
                data: Data(
                    #"{"link":"https://dl.opensubtitles.com/subtitles/123","file_name":"shared.srt"}"#.utf8
                ),
                statusCode: 200,
                headers: [:]
            )
        }
        subtitleRequestCount += 1
        return OpenSubtitlesHTTPResponse(
            data: Data("1\n00:00:01,000 --> 00:00:02,000\nShared\n".utf8),
            statusCode: 200,
            headers: [:]
        )
    }

    func requestCounts() -> (downloadDescriptor: Int, subtitleFile: Int) {
        (descriptorRequestCount, subtitleRequestCount)
    }
}

private final class MockCredentialStore: OpenSubtitlesCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAPIKey: String?
    private var storedSession: OpenSubtitlesStoredSession?
    private(set) var persistedPassword: String?

    init(apiKey: String?) {
        storedAPIKey = apiKey
    }

    func apiKey() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storedAPIKey
    }

    func storeAPIKey(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storedAPIKey = key
    }

    func removeAPIKey() throws {
        lock.lock(); defer { lock.unlock() }
        storedAPIKey = nil
        storedSession = nil
    }

    func session() throws -> OpenSubtitlesStoredSession? {
        lock.lock(); defer { lock.unlock() }
        return storedSession
    }

    func storeSession(_ session: OpenSubtitlesStoredSession) throws {
        lock.lock(); defer { lock.unlock() }
        storedSession = session
    }

    func removeSession() throws {
        lock.lock(); defer { lock.unlock() }
        storedSession = nil
    }
}
