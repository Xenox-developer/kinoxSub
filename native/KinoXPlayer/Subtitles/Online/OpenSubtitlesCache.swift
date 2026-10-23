import CryptoKit
import Foundation

struct OpenSubtitlesPersistentArtifactLocation: Equatable {
    let fileID: Int
    let movieFolderName: String?
}

actor OpenSubtitlesCache {
    private static let maximumCueTime: TimeInterval = 7 * 24 * 60 * 60
    private static let legacyMigrationMarkerName = ".legacy-cache-migrated-v1"
    private static let maximumMovieFolderNameBytes = 180
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil) throws {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = try Self.ensureDefaultRootDirectory(fileManager: fileManager)
        }
    }

    static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw OpenSubtitlesError.cache(message: "папка приложения недоступна")
        }
        return applicationSupport
            .appendingPathComponent("KinoXPlayer", isDirectory: true)
            .appendingPathComponent("Downloaded Subtitles", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    static func legacyRootURL(fileManager: FileManager = .default) throws -> URL {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw OpenSubtitlesError.cache(message: "папка старого кэша недоступна")
        }
        return caches
            .appendingPathComponent("KinoXPlayer", isDirectory: true)
            .appendingPathComponent("Subtitles", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    static func ensureDefaultRootDirectory(fileManager: FileManager = .default) throws -> URL {
        let rootURL = try defaultRootURL(fileManager: fileManager)
        try prepareDirectory(at: rootURL, fileManager: fileManager)
        let markerURL = rootURL.appendingPathComponent(
            legacyMigrationMarkerName,
            isDirectory: false
        )
        if !fileManager.fileExists(atPath: markerURL.path),
           let legacyRootURL = try? legacyRootURL(fileManager: fileManager) {
            do {
                _ = try migrateLegacyFiles(
                    from: legacyRootURL,
                    to: rootURL,
                    fileManager: fileManager
                )
                try Data().write(to: markerURL, options: [.atomic])
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: markerURL.path
                )
            } catch {
                try? fileManager.removeItem(at: markerURL)
            }
        }
        return rootURL
    }

    static func fileName(for fileID: Int) -> String {
        "opensubtitles-\(fileID).srt"
    }

    static func movieFolderName(for videoURL: URL) -> String {
        let identity = videoURL.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(6)
            .map { String(format: "%02X", $0) }
            .joined()
        let suffix = " — \(digest)"
        let title = sanitizedMovieFolderComponent(
            videoURL.deletingPathExtension().lastPathComponent,
            maximumBytes: maximumMovieFolderNameBytes - suffix.utf8.count
        )
        return title + suffix
    }

    static func movieFolderName(forVideoName rawName: String) -> String {
        sanitizedMovieFolderComponent(
            rawName,
            maximumBytes: maximumMovieFolderNameBytes
        )
    }

    private static func sanitizedMovieFolderComponent(
        _ rawName: String,
        maximumBytes: Int
    ) -> String {
        let bidiControlScalars: Set<UInt32> = [
            0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069
        ]
        let unsafePathScalars = CharacterSet(charactersIn: "/\\:")
        var cleaned = ""

        for scalar in rawName.precomposedStringWithCanonicalMapping.unicodeScalars {
            if bidiControlScalars.contains(scalar.value) {
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) {
                cleaned.append(" ")
            } else if unsafePathScalars.contains(scalar) {
                cleaned.append("-")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }

        let collapsed = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
            )
        let candidate = collapsed.isEmpty ? "Фильм" : collapsed
        var result = ""
        var byteCount = 0
        for character in candidate {
            let text = String(character)
            let bytes = text.utf8.count
            guard byteCount + bytes <= maximumBytes else { break }
            result.append(character)
            byteCount += bytes
        }
        return result.isEmpty ? "Фильм" : result
    }

    static func movieFolderURL(
        for videoURL: URL,
        createIfNeeded: Bool = true,
        fileManager: FileManager = .default
    ) throws -> URL {
        let rootURL = try ensureDefaultRootDirectory(fileManager: fileManager)
        return try movieFolderURL(
            for: videoURL,
            rootURL: rootURL,
            createIfNeeded: createIfNeeded,
            fileManager: fileManager
        )
    }

    static func movieFolderURL(
        for videoURL: URL,
        rootURL: URL,
        createIfNeeded: Bool = true,
        fileManager: FileManager = .default
    ) throws -> URL {
        try prepareDirectory(at: rootURL, fileManager: fileManager)
        let folderName = movieFolderName(for: videoURL)
        let folderURL = rootURL.appendingPathComponent(folderName, isDirectory: true)
        if createIfNeeded {
            try prepareMovieDirectory(
                at: folderURL,
                rootURL: rootURL,
                fileManager: fileManager
            )
        }
        return folderURL
    }

    static func fileID(fromFileName fileName: String) -> Int? {
        let prefix = "opensubtitles-"
        let suffix = ".srt"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        let digits = String(fileName[start..<end])
        guard !digits.isEmpty,
              digits.allSatisfy(\.isNumber),
              !digits.hasPrefix("0"),
              let fileID = Int(digits),
              fileID > 0 else {
            return nil
        }
        return fileID
    }

    static func persistentArtifactURL(
        for fileID: Int,
        movieFolderName: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard fileID > 0 else { throw OpenSubtitlesError.invalidPayload }
        let rootURL = try ensureDefaultRootDirectory(fileManager: fileManager)
        let directoryURL = try persistentDirectoryURL(
            movieFolderName: movieFolderName,
            rootURL: rootURL,
            fileManager: fileManager
        )
        return directoryURL
            .appendingPathComponent(fileName(for: fileID), isDirectory: false)
    }

    static func persistentArtifactLocation(
        for fileURL: URL,
        fileManager: FileManager = .default
    ) -> OpenSubtitlesPersistentArtifactLocation? {
        guard let rootURL = try? defaultRootURL(fileManager: fileManager) else {
            return nil
        }
        return persistentArtifactLocation(
            for: fileURL,
            rootURL: rootURL,
            fileManager: fileManager
        )
    }

    static func persistentArtifactLocation(
        for fileURL: URL,
        rootURL: URL,
        fileManager: FileManager = .default
    ) -> OpenSubtitlesPersistentArtifactLocation? {
        do {
            try validateOwnedCachePath(rootURL, fileManager: fileManager)
        } catch {
            return nil
        }
        let standardizedRoot = rootURL.standardizedFileURL
        let standardizedFile = fileURL.standardizedFileURL
        let parentURL = standardizedFile.deletingLastPathComponent()

        let resolvedMovieFolderName: String?
        if parentURL == standardizedRoot {
            resolvedMovieFolderName = nil
        } else {
            let canonicalFolderName = parentURL.lastPathComponent
                .precomposedStringWithCanonicalMapping
            guard parentURL.deletingLastPathComponent() == standardizedRoot,
                  canonicalFolderName
                    == movieFolderName(forVideoName: canonicalFolderName),
                  let parentValues = try? parentURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  parentValues.isDirectory == true,
                  parentValues.isSymbolicLink != true else {
                return nil
            }
            resolvedMovieFolderName = canonicalFolderName
        }

        guard let rootValues = try? standardizedRoot.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              let fileID = fileID(fromFileName: standardizedFile.lastPathComponent),
              let values = try? standardizedFile.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= OpenSubtitlesURLSessionTransport.maximumSubtitleBytes else {
            return nil
        }
        return OpenSubtitlesPersistentArtifactLocation(
            fileID: fileID,
            movieFolderName: resolvedMovieFolderName
        )
    }

    static func fileID(
        forPersistentArtifactURL fileURL: URL,
        fileManager: FileManager = .default
    ) -> Int? {
        persistentArtifactLocation(
            for: fileURL,
            fileManager: fileManager
        )?.fileID
    }

    func cachedArtifact(
        fileID: Int,
        movieFolderName: String? = nil
    ) throws -> MaterializedOpenSubtitle? {
        guard fileID > 0 else { throw OpenSubtitlesError.invalidPayload }
        let url = try cachedURL(
            fileID: fileID,
            movieFolderName: movieFolderName
        )
        if !fileManager.fileExists(atPath: url.path) {
            // Version 1.4 stored all downloads directly in the library root.
            // Promote a valid flat artifact into the current movie folder so
            // an already downloaded subtitle never consumes quota again.
            if movieFolderName != nil {
                let flatURL = rootURL.appendingPathComponent(
                    Self.fileName(for: fileID),
                    isDirectory: false
                )
                if let parsed = try parsedArtifact(at: flatURL) {
                    return try store(
                        fileID: fileID,
                        cues: parsed.cues,
                        movieFolderName: movieFolderName
                    )
                }
                if let parsed = firstNestedArtifact(
                    fileID: fileID,
                    excludingMovieFolderName: movieFolderName
                ) {
                    return try store(
                        fileID: fileID,
                        cues: parsed.cues,
                        movieFolderName: movieFolderName
                    )
                }
            }
            return nil
        }

        guard let parsed = try parsedArtifact(at: url) else { return nil }
        return MaterializedOpenSubtitle(
            fileID: fileID,
            fileURL: url,
            cueCount: parsed.cues.count,
            encodingName: parsed.encodingName
        )
    }

    func store(
        fileID: Int,
        cues: [SubtitleCue],
        movieFolderName: String? = nil
    ) throws -> MaterializedOpenSubtitle {
        guard fileID > 0, Self.areValid(cues: cues) else {
            throw OpenSubtitlesError.invalidPayload
        }
        let data = try Self.canonicalSRT(cues: cues)
        guard data.count <= OpenSubtitlesURLSessionTransport.maximumSubtitleBytes else {
            throw OpenSubtitlesError.payloadTooLarge(
                maximumBytes: OpenSubtitlesURLSessionTransport.maximumSubtitleBytes
            )
        }

        do {
            let destination = try cachedURL(
                fileID: fileID,
                movieFolderName: movieFolderName
            )
            try Self.writePersistentData(
                data,
                to: destination,
                fileManager: fileManager
            )
            return MaterializedOpenSubtitle(
                fileID: fileID,
                fileURL: destination,
                cueCount: cues.count,
                encodingName: "UTF-8"
            )
        } catch let error as OpenSubtitlesError {
            throw error
        } catch {
            throw OpenSubtitlesError.cache(message: "запись в папку фильма не удалась")
        }
    }

    static func copyArtifactToMovieFolder(
        fileID: Int,
        cues: [SubtitleCue],
        toMovieFolderFor videoURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard fileID > 0, areValid(cues: cues) else {
            throw OpenSubtitlesError.invalidPayload
        }
        let data = try canonicalSRT(cues: cues)
        guard data.count <= OpenSubtitlesURLSessionTransport.maximumSubtitleBytes else {
            throw OpenSubtitlesError.payloadTooLarge(
                maximumBytes: OpenSubtitlesURLSessionTransport.maximumSubtitleBytes
            )
        }
        let folderURL = try movieFolderURL(
            for: videoURL,
            createIfNeeded: true,
            fileManager: fileManager
        )
        let destination = folderURL.appendingPathComponent(
            fileName(for: fileID),
            isDirectory: false
        )
        try writePersistentData(data, to: destination, fileManager: fileManager)
        return destination
    }

    private func parsedArtifact(at url: URL) throws -> ParsedSubtitle? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw OpenSubtitlesError.cache(message: "не удалось проверить сохранённый файл")
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return nil
        }
        guard let size = values.fileSize,
              size <= OpenSubtitlesURLSessionTransport.maximumSubtitleBytes else {
            try? fileManager.removeItem(at: url)
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw OpenSubtitlesError.cache(message: "не удалось прочитать сохранённый файл")
        }

        do {
            let parsed = try SubtitleParser.parse(data: data)
            guard Self.areValid(cues: parsed.cues) else {
                try? fileManager.removeItem(at: url)
                return nil
            }
            return parsed
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    private func firstNestedArtifact(
        fileID: Int,
        excludingMovieFolderName: String?
    ) -> ParsedSubtitle? {
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return nil
        }

        for folderURL in children {
            let folderName = folderURL.lastPathComponent
                .precomposedStringWithCanonicalMapping
            guard folderName != excludingMovieFolderName,
                  folderName == Self.movieFolderName(forVideoName: folderName),
                  let values = try? folderURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                continue
            }
            let candidateURL = folderURL.appendingPathComponent(
                Self.fileName(for: fileID),
                isDirectory: false
            )
            if let parsed = try? parsedArtifact(at: candidateURL) {
                return parsed
            }
        }
        return nil
    }

    private func cachedURL(
        fileID: Int,
        movieFolderName: String?
    ) throws -> URL {
        let directoryURL = try Self.persistentDirectoryURL(
            movieFolderName: movieFolderName,
            rootURL: rootURL,
            fileManager: fileManager
        )
        return directoryURL.appendingPathComponent(
            Self.fileName(for: fileID),
            isDirectory: false
        )
    }

    private func prepareDirectory() throws {
        try Self.prepareDirectory(at: rootURL, fileManager: fileManager)
    }

    private static func persistentDirectoryURL(
        movieFolderName: String?,
        rootURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        try prepareDirectory(at: rootURL, fileManager: fileManager)
        guard let movieFolderName else { return rootURL }
        guard movieFolderName == self.movieFolderName(forVideoName: movieFolderName) else {
            throw OpenSubtitlesError.cache(message: "небезопасное имя папки фильма")
        }
        let folderURL = rootURL.appendingPathComponent(
            movieFolderName,
            isDirectory: true
        )
        try prepareMovieDirectory(
            at: folderURL,
            rootURL: rootURL,
            fileManager: fileManager
        )
        return folderURL
    }

    private static func prepareMovieDirectory(
        at folderURL: URL,
        rootURL: URL,
        fileManager: FileManager
    ) throws {
        guard folderURL.standardizedFileURL.deletingLastPathComponent()
                == rootURL.standardizedFileURL,
              folderURL.lastPathComponent
                == movieFolderName(forVideoName: folderURL.lastPathComponent) else {
            throw OpenSubtitlesError.cache(message: "небезопасное имя папки фильма")
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) {
            let values = try folderURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard isDirectory.boolValue,
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw OpenSubtitlesError.cache(message: "папка фильма недоступна")
            }
        } else {
            try fileManager.createDirectory(
                at: folderURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: folderURL.path
        )
    }

    private static func writePersistentData(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw OpenSubtitlesError.cache(message: "небезопасный файл назначения")
            }
        }
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    private static func prepareDirectory(at rootURL: URL, fileManager: FileManager) throws {
        try validateOwnedCachePath(rootURL, fileManager: fileManager)
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    private static func validateOwnedCachePath(_ rootURL: URL, fileManager: FileManager) throws {
        let subtitlesDirectory = rootURL.deletingLastPathComponent()
        let applicationDirectory = subtitlesDirectory.deletingLastPathComponent()
        for url in [applicationDirectory, subtitlesDirectory, rootURL] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard isDirectory.boolValue,
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw OpenSubtitlesError.cache(
                    message: "небезопасный путь папки загруженных субтитров"
                )
            }
        }
    }

    @discardableResult
    static func migrateLegacyFiles(
        from legacyRootURL: URL,
        to destinationRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> Int {
        try prepareDirectory(at: destinationRootURL, fileManager: fileManager)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyRootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let legacyValues = try? legacyRootURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              legacyValues.isDirectory == true,
              legacyValues.isSymbolicLink != true else {
            return 0
        }

        let candidates = try fileManager.contentsOfDirectory(
            at: legacyRootURL,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        var migratedCount = 0

        for sourceURL in candidates {
            guard let fileID = fileID(fromFileName: sourceURL.lastPathComponent) else {
                continue
            }
            let destinationURL = destinationRootURL.appendingPathComponent(
                fileName(for: fileID),
                isDirectory: false
            )
            if isValidArtifact(at: destinationURL, fileManager: fileManager) {
                continue
            }

            guard let sourceValues = try? sourceURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  sourceValues.isRegularFile == true,
                  sourceValues.isSymbolicLink != true,
                  let sourceSize = sourceValues.fileSize,
                  sourceSize <= OpenSubtitlesURLSessionTransport.maximumSubtitleBytes,
                  let sourceData = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]),
                  let parsed = try? SubtitleParser.parse(data: sourceData),
                  areValid(cues: parsed.cues),
                  let canonicalData = try? canonicalSRT(cues: parsed.cues),
                  canonicalData.count <= OpenSubtitlesURLSessionTransport.maximumSubtitleBytes else {
                continue
            }
            if fileManager.fileExists(atPath: destinationURL.path) {
                guard let destinationValues = try? destinationURL.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ),
                      destinationValues.isRegularFile == true,
                      destinationValues.isSymbolicLink != true else {
                    continue
                }
                try? fileManager.removeItem(at: destinationURL)
            }

            do {
                try canonicalData.write(to: destinationURL, options: [.atomic])
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destinationURL.path
                )
                guard isValidArtifact(at: destinationURL, fileManager: fileManager) else {
                    try? fileManager.removeItem(at: destinationURL)
                    continue
                }
                migratedCount += 1
            } catch {
                try? fileManager.removeItem(at: destinationURL)
            }
        }
        return migratedCount
    }

    private static func isValidArtifact(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= OpenSubtitlesURLSessionTransport.maximumSubtitleBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let parsed = try? SubtitleParser.parse(data: data),
              areValid(cues: parsed.cues) else {
            return false
        }
        return true
    }

    private static func areValid(cues: [SubtitleCue]) -> Bool {
        !cues.isEmpty
            && cues.count <= 100_000
            && cues.allSatisfy { cue in
                cue.start.isFinite
                    && cue.end.isFinite
                    && cue.start >= 0
                    && cue.end > cue.start
                    && cue.end <= maximumCueTime
            }
    }

    private static func canonicalSRT(cues: [SubtitleCue]) throws -> Data {
        let blocks = try cues.enumerated().map { index, cue in
            "\(index + 1)\n\(try timestamp(cue.start)) --> \(try timestamp(cue.end))\n\(cue.text)"
        }
        let body = blocks.joined(separator: "\n\n") + "\n"
        return Data(body.utf8)
    }

    private static func timestamp(_ time: TimeInterval) throws -> String {
        guard time.isFinite, time >= 0, time <= maximumCueTime else {
            throw OpenSubtitlesError.invalidPayload
        }
        let totalMilliseconds = Int64((time * 1_000).rounded())
        let milliseconds = totalMilliseconds % 1_000
        let totalSeconds = totalMilliseconds / 1_000
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        return String(
            format: "%02lld:%02lld:%02lld,%03lld",
            hours, minutes, seconds, milliseconds
        )
    }
}
