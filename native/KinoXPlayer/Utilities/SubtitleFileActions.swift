import AppKit
import Foundation
import UniformTypeIdentifiers

enum SubtitleFileActionError: LocalizedError {
    case sourceMissing
    case cannotOpenFolder
    case cannotRevealFile

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "Файл субтитров больше не найден. Возможно, он был удалён из медиатеки."
        case .cannotOpenFolder:
            return "Не удалось открыть папку загруженных субтитров."
        case .cannotRevealFile:
            return "Не удалось показать файл субтитров в Finder."
        }
    }
}

enum SubtitleFileActions {
    typealias SaveCompletion = @MainActor (Result<URL?, Error>) -> Void

    @MainActor
    @discardableResult
    static func openDownloadedSubtitlesFolder(for videoURL: URL? = nil) throws -> URL {
        let folderURL: URL
        if let videoURL {
            folderURL = try OpenSubtitlesCache.movieFolderURL(for: videoURL)
        } else {
            folderURL = try OpenSubtitlesCache.ensureDefaultRootDirectory()
        }
        return try openSubtitleFolder(folderURL)
    }

    @MainActor
    @discardableResult
    static func openSubtitleFolder(_ folderURL: URL) throws -> URL {
        let values = try? folderURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values?.isDirectory == true,
              values?.isSymbolicLink != true,
              NSWorkspace.shared.open(folderURL) else {
            throw SubtitleFileActionError.cannotOpenFolder
        }
        return folderURL
    }

    @MainActor
    static func revealInFinder(_ fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SubtitleFileActionError.sourceMissing
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @MainActor
    static func presentSaveCopy(
        of sourceURL: URL,
        suggestedName: String?,
        initialDirectoryURL: URL? = nil,
        completion: @escaping SaveCompletion
    ) {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            completion(.failure(SubtitleFileActionError.sourceMissing))
            return
        }

        let panel = NSSavePanel()
        panel.title = "Сохранить копию субтитров"
        panel.prompt = "Сохранить"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = initialDirectoryURL
        panel.nameFieldStringValue = safeSuggestedFileName(
            suggestedName,
            sourceURL: sourceURL
        )
        if let contentType = UTType(filenameExtension: sourceURL.pathExtension.lowercased()) {
            panel.allowedContentTypes = [contentType]
        }

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else {
                completion(.success(nil))
                return
            }

            Task.detached(priority: .utility) {
                let result: Result<URL?, Error>
                do {
                    try writeCopy(from: sourceURL, to: destinationURL)
                    result = .success(destinationURL)
                } catch {
                    result = .failure(error)
                }
                await MainActor.run {
                    completion(result)
                }
            }
        }
    }

    static func safeSuggestedFileName(_ preferredName: String?, sourceURL: URL) -> String {
        let fallbackExtension = supportedExtension(sourceURL.pathExtension) ?? "srt"
        let preferred = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmed = preferred.isEmpty ? sourceURL.lastPathComponent : preferred
        var name = (trimmed as NSString).lastPathComponent
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty || name == "." || name == ".." {
            name = "Субтитры.\(fallbackExtension)"
        }

        let currentExtension = (name as NSString).pathExtension.lowercased()
        let base: String
        if supportedExtension(currentExtension) != nil {
            base = (name as NSString).deletingPathExtension
        } else {
            // A final dotted token is often a language/release tag, not an extension.
            base = name
        }
        return filename(base: base, extension: fallbackExtension)
    }

    static func writeCopy(from sourceURL: URL, to destinationURL: URL) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw SubtitleFileActionError.sourceMissing
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let didAccessDestination = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessDestination { destinationURL.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        if let coordinationError { throw coordinationError }
    }

    private static func filename(base: String, extension pathExtension: String) -> String {
        let suffix = ".\(pathExtension)"
        let maximumBytes = 240
        let baseBudget = max(1, maximumBytes - suffix.utf8.count)
        let trimmedBase = base.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        )
        let candidate = trimmedBase.isEmpty ? "Субтитры" : trimmedBase
        var result = ""
        var byteCount = 0
        for character in candidate {
            let characterText = String(character)
            let characterBytes = characterText.utf8.count
            guard byteCount + characterBytes <= baseBudget else { break }
            result.append(character)
            byteCount += characterBytes
        }
        if result.isEmpty { result = "Субтитры" }
        return result + suffix
    }

    private static func supportedExtension(_ value: String) -> String? {
        let normalized = value.lowercased()
        return ["srt", "vtt"].contains(normalized) ? normalized : nil
    }
}
