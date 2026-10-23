import Foundation

struct SubtitleCandidateScorer: Sendable {
    func score(
        video: SubtitleSearchVideo,
        subtitleURL: URL,
        cues: [SubtitleCue]
    ) -> SubtitleMatchScore {
        let fileNameScore = Self.fileNameScore(
            videoURL: video.url,
            subtitleURL: subtitleURL
        )
        let durationScore = video.duration.map { duration in
            Self.durationScore(cues: cues, videoDuration: duration)
        }
        let timelineScore = Self.timelineScore(cues: cues, videoDuration: video.duration)

        let totalScore: Double
        if let durationScore {
            totalScore = fileNameScore * 0.40
                + durationScore * 0.38
                + timelineScore * 0.22
        } else {
            totalScore = fileNameScore * 0.68 + timelineScore * 0.32
        }

        return SubtitleMatchScore(
            totalScore: Self.clamp(totalScore),
            fileNameScore: fileNameScore,
            durationScore: durationScore,
            timelineScore: timelineScore
        )
    }

    private static func fileNameScore(videoURL: URL, subtitleURL: URL) -> Double {
        let videoName = searchableName(for: videoURL)
        let subtitleName = searchableName(for: subtitleURL)
        guard !videoName.titleTokens.isEmpty, !subtitleName.titleTokens.isEmpty else {
            return matchingYearScore(video: videoName.years, subtitle: subtitleName.years)
        }

        let tokenScore = diceCoefficient(videoName.titleTokens, subtitleName.titleTokens)
        let compactVideoTitle = videoName.titleTokens.sorted().joined()
        let compactSubtitleTitle = subtitleName.titleTokens.sorted().joined()
        let characterScore = diceCoefficient(
            ngrams(in: compactVideoTitle, size: 3),
            ngrams(in: compactSubtitleTitle, size: 3)
        )
        var score = max(tokenScore, characterScore * 0.9)

        if !videoName.years.isEmpty, !subtitleName.years.isEmpty {
            if !videoName.years.isDisjoint(with: subtitleName.years) {
                score = 0.12 + score * 0.88
            } else {
                score *= 0.15
            }
        }

        return clamp(score)
    }

    private static func durationScore(cues: [SubtitleCue], videoDuration: TimeInterval) -> Double {
        guard videoDuration.isFinite,
              videoDuration > 0,
              let lastCueEnd = cues.last?.end,
              lastCueEnd.isFinite,
              lastCueEnd > 0 else {
            return 0
        }

        let endRatio = lastCueEnd / videoDuration
        let idealEndRatio = 0.97
        if endRatio <= idealEndRatio {
            let distance = (idealEndRatio - endRatio) / 0.52
            return clamp(1 - pow(max(distance, 0), 1.35))
        }

        let distance = (endRatio - idealEndRatio) / 0.18
        return clamp(1 - pow(max(distance, 0), 1.25))
    }

    private static func timelineScore(
        cues: [SubtitleCue],
        videoDuration: TimeInterval?
    ) -> Double {
        guard !cues.isEmpty else { return 0 }

        let cueCountScore = clamp(
            log(Double(cues.count) + 1) / log(201)
        )

        let reasonableCueCount = cues.reduce(into: 0) { count, cue in
            let cueDuration = cue.end - cue.start
            if cue.start.isFinite,
               cue.end.isFinite,
               cue.start >= 0,
               (0.1...20).contains(cueDuration) {
                count += 1
            }
        }
        let cueHealthScore = Double(reasonableCueCount) / Double(cues.count)

        let firstStart = cues.first?.start ?? 0
        let lastEnd = cues.last?.end ?? firstStart
        let spanMinutes = max((lastEnd - firstStart) / 60, 1.0 / 60)
        let cuesPerMinute = Double(cues.count) / spanMinutes
        let densityScore: Double
        switch cuesPerMinute {
        case 0.2...30: densityScore = 1
        case 0.05..<0.2, 30...60: densityScore = 0.55
        default: densityScore = 0.15
        }

        let boundsScore: Double
        if let videoDuration, videoDuration.isFinite, videoDuration > 0 {
            let tolerance = max(60, videoDuration * 0.02)
            let inBoundsCount = cues.reduce(into: 0) { count, cue in
                if cue.start >= 0, cue.end <= videoDuration + tolerance {
                    count += 1
                }
            }
            boundsScore = Double(inBoundsCount) / Double(cues.count)
        } else {
            boundsScore = 1
        }

        return clamp(
            cueCountScore * 0.30
                + cueHealthScore * 0.35
                + densityScore * 0.20
                + boundsScore * 0.15
        )
    }

    private struct SearchableName {
        let titleTokens: Set<String>
        let years: Set<String>
    }

    private static func searchableName(for url: URL) -> SearchableName {
        let folded = url
            .deletingPathExtension()
            .lastPathComponent
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let sanitized = String(folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        })
        let tokens = sanitized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let years = Set(tokens.filter(isYear))
        let titleTokens = Set(tokens.filter { token in
            !isYear(token) && !isReleaseNoise(token)
        })
        return SearchableName(titleTokens: titleTokens, years: years)
    }

    private static func isYear(_ token: String) -> Bool {
        guard token.count == 4, let value = Int(token) else { return false }
        return (1888...2100).contains(value)
    }

    private static func matchingYearScore(video: Set<String>, subtitle: Set<String>) -> Double {
        guard !video.isEmpty, !subtitle.isEmpty else { return 0 }
        return video.isDisjoint(with: subtitle) ? 0 : 0.12
    }

    private static func isReleaseNoise(_ token: String) -> Bool {
        if releaseNoiseTokens.contains(token) { return true }
        if token.range(of: #"^\d{3,4}p$"#, options: .regularExpression) != nil { return true }
        if token.range(of: #"^(x|h)26[45]$"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static let releaseNoiseTokens: Set<String> = [
        "aac", "ac3", "bdrip", "bluray", "cc", "complete", "de", "deu", "dolby",
        "dts", "dv", "en", "eng", "forced", "full", "ger", "german", "hdr", "hevc",
        "proper", "remux", "repack", "ru", "rus", "russian", "sdh", "sub", "subs",
        "subtitle", "subtitles", "uhd", "web", "webdl", "webrip"
    ]

    private static func ngrams(in value: String, size: Int) -> Set<String> {
        let characters = Array(value)
        guard characters.count >= size else {
            return value.isEmpty ? [] : [value]
        }

        return Set((0...(characters.count - size)).map { index in
            String(characters[index..<(index + size)])
        })
    }

    private static func diceCoefficient<T: Hashable>(_ lhs: Set<T>, _ rhs: Set<T>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        let intersectionCount = lhs.intersection(rhs).count
        return Double(intersectionCount * 2) / Double(lhs.count + rhs.count)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}
