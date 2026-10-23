import Foundation

struct LocalSubtitleCandidateFinder: Sendable {
    private let scorer = SubtitleCandidateScorer()

    func findCandidates(
        in folderURL: URL,
        for video: SubtitleSearchVideo,
        options: SubtitleSearchOptions = SubtitleSearchOptions()
    ) throws -> SubtitleSearchResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) else {
            throw LocalSubtitleSearchError.folderDoesNotExist(folderURL)
        }
        guard isDirectory.boolValue else {
            throw LocalSubtitleSearchError.selectedURLIsNotFolder(folderURL)
        }

        let discoveredURLs = try subtitleFileURLs(
            in: folderURL,
            recursive: options.recursive,
            fileManager: fileManager
        )
        let sortedURLs = discoveredURLs.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        let wasTruncated = sortedURLs.count > options.maxCandidateFiles
        let inspectedURLs = sortedURLs.prefix(options.maxCandidateFiles)

        var candidates: [SubtitleCandidate] = []
        var rejectedCandidates: [RejectedSubtitleCandidate] = []

        for url in inspectedURLs {
            do {
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard resourceValues.isRegularFile == true else { continue }
                let reportedSize = resourceValues.fileSize ?? 0
                if reportedSize > options.maxFileSizeBytes {
                    rejectedCandidates.append(RejectedSubtitleCandidate(
                        url: url,
                        reason: .tooLarge(
                            actualBytes: reportedSize,
                            limitBytes: options.maxFileSizeBytes
                        )
                    ))
                    continue
                }

                let data: Data
                do {
                    data = try Data(contentsOf: url, options: .mappedIfSafe)
                } catch {
                    rejectedCandidates.append(RejectedSubtitleCandidate(
                        url: url,
                        reason: .unreadable(error.localizedDescription)
                    ))
                    continue
                }

                if data.count > options.maxFileSizeBytes {
                    rejectedCandidates.append(RejectedSubtitleCandidate(
                        url: url,
                        reason: .tooLarge(
                            actualBytes: data.count,
                            limitBytes: options.maxFileSizeBytes
                        )
                    ))
                    continue
                }

                let parsed: ParsedSubtitle
                do {
                    parsed = try SubtitleParser.parse(data: data)
                } catch {
                    rejectedCandidates.append(RejectedSubtitleCandidate(
                        url: url,
                        reason: .parsingFailed(error.localizedDescription)
                    ))
                    continue
                }
                guard !parsed.cues.isEmpty else {
                    rejectedCandidates.append(RejectedSubtitleCandidate(url: url, reason: .noCues))
                    continue
                }
                guard let format = SubtitleFileFormat(fileURL: url) else { continue }

                candidates.append(SubtitleCandidate(
                    url: url,
                    format: format,
                    encodingName: parsed.encodingName,
                    cues: parsed.cues,
                    fileSizeBytes: data.count,
                    score: scorer.score(video: video, subtitleURL: url, cues: parsed.cues)
                ))
            } catch {
                rejectedCandidates.append(RejectedSubtitleCandidate(
                    url: url,
                    reason: .unreadable(error.localizedDescription)
                ))
            }
        }

        candidates.sort {
            if $0.score.totalScore != $1.score.totalScore {
                return $0.score.totalScore > $1.score.totalScore
            }
            if $0.score.fileNameScore != $1.score.fileNameScore {
                return $0.score.fileNameScore > $1.score.fileNameScore
            }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        rejectedCandidates.sort {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }

        return SubtitleSearchResult(
            candidates: candidates,
            rejectedCandidates: rejectedCandidates,
            wasTruncated: wasTruncated
        )
    }

    private func subtitleFileURLs(
        in rootFolderURL: URL,
        recursive: Bool,
        fileManager: FileManager
    ) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        var pendingFolders = [rootFolderURL]
        var visitedFolders: Set<URL> = []
        var subtitleURLs: [URL] = []

        while let folderURL = pendingFolders.popLast() {
            let standardizedFolderURL = folderURL.standardizedFileURL
            guard visitedFolders.insert(standardizedFolderURL).inserted else { continue }

            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles]
                )
            } catch {
                if standardizedFolderURL == rootFolderURL.standardizedFileURL {
                    throw LocalSubtitleSearchError.unableToEnumerate(
                        rootFolderURL,
                        error.localizedDescription
                    )
                }
                continue
            }

            for childURL in children {
                let values = try? childURL.resourceValues(forKeys: resourceKeys)
                if values?.isDirectory == true {
                    if recursive,
                       values?.isPackage != true,
                       values?.isSymbolicLink != true {
                        pendingFolders.append(childURL)
                    }
                    continue
                }

                guard values?.isRegularFile == true,
                      SubtitleFileFormat(fileURL: childURL) != nil else {
                    continue
                }
                subtitleURLs.append(childURL.standardizedFileURL)
            }

            if !recursive { break }
        }

        return Array(Set(subtitleURLs))
    }
}
