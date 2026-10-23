import Foundation
import SoundAnalysis

enum SubtitleCompatibilityVerdict: Sendable {
    case suitable
    case timeOffset(seconds: TimeInterval)
    case frameRate(subtitleFPS: Double?, videoFPS: Double?)
    case differentEdit
    case unverified
}

struct SubtitleSearchMatch: Sendable {
    let candidate: SubtitleCandidate
    let verdict: SubtitleCompatibilityVerdict
    let timingTransform: SubtitleTimingTransform?
    let audioMatchScore: Double?
    let confidence: Double
}

enum SubtitleCompatibilityError: LocalizedError {
    case noVideo
    case soundClassifierUnavailable
    case audioAnalysisFailed(String)
    case audioAnalysisCancelled
    case insufficientAudio

    var errorDescription: String? {
        switch self {
        case .noVideo:
            return "Сначала откройте видео."
        case .soundClassifierUnavailable:
            return "Системная проверка речи недоступна на этом Mac."
        case .audioAnalysisFailed(let message):
            return "Не удалось проверить аудио: \(message)"
        case .audioAnalysisCancelled:
            return "Проверка аудио отменена."
        case .insufficientAudio:
            return "В фильме недостаточно речи для уверенной проверки."
        }
    }
}

/// Searches local subtitle files and compares their cue activity with the speech
/// probability produced by Apple's on-device sound classifier. No movie data is
/// uploaded and no microphone permission is required.
actor LocalSubtitleSearchService {
    private let finder = LocalSubtitleCandidateFinder()
    private var cachedProfiles: [SubtitleSpeechProfileKey: SubtitleSpeechProfile] = [:]
    private var profileTasks: [SubtitleSpeechProfileKey: Task<SubtitleSpeechProfile, Error>] = [:]

    func search(
        in folderURL: URL,
        for video: SubtitleSearchVideo,
        options: SubtitleSearchOptions = SubtitleSearchOptions()
    ) async throws -> [SubtitleSearchMatch] {
        try Task.checkCancellation()
        let searchResult = try finder.findCandidates(
            in: folderURL,
            for: video,
            options: options
        )
        guard !searchResult.candidates.isEmpty else { return [] }

        let profile: SubtitleSpeechProfile
        do {
            profile = try await speechProfile(for: video.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch SubtitleCompatibilityError.audioAnalysisCancelled {
            throw CancellationError()
        } catch {
            return searchResult.candidates.map {
                SubtitleSearchMatch(
                    candidate: $0,
                    verdict: .unverified,
                    timingTransform: nil,
                    audioMatchScore: nil,
                    confidence: min($0.score.totalScore * 0.55, 0.49)
                )
            }
        }

        let comparisonSamples = profile.distributedDialogueSamples(
            videoDuration: video.duration
        )
        guard comparisonSamples.count >= 120 else {
            return searchResult.candidates.map {
                SubtitleSearchMatch(
                    candidate: $0,
                    verdict: .unverified,
                    timingTransform: nil,
                    audioMatchScore: nil,
                    confidence: min($0.score.totalScore * 0.55, 0.49)
                )
            }
        }

        var matches: [SubtitleSearchMatch] = []
        matches.reserveCapacity(searchResult.candidates.count)

        // Audio comparison is intentionally bounded. Remaining files are still
        // shown using metadata, so a folder with hundreds of subtitle files does
        // not turn into minutes of CPU work.
        for (index, candidate) in searchResult.candidates.enumerated() {
            try Task.checkCancellation()
            if index < 40 {
                matches.append(SubtitleCompatibilityMatcher.match(
                    candidate: candidate,
                    video: video,
                    samples: comparisonSamples
                ))
            } else {
                matches.append(SubtitleSearchMatch(
                    candidate: candidate,
                    verdict: .unverified,
                    timingTransform: nil,
                    audioMatchScore: nil,
                    confidence: min(candidate.score.totalScore * 0.55, 0.49)
                ))
            }
        }

        return matches.sorted(by: SubtitleCompatibilityMatcher.sortsBefore)
    }

    func synchronize(
        candidate: SubtitleCandidate,
        with video: SubtitleSearchVideo
    ) async throws -> SubtitleSearchMatch {
        try Task.checkCancellation()
        let profile = try await speechProfile(for: video.url)
        try Task.checkCancellation()

        let comparisonSamples = profile.distributedDialogueSamples(
            videoDuration: video.duration
        )
        guard comparisonSamples.count >= 120 else {
            throw SubtitleCompatibilityError.insufficientAudio
        }

        return SubtitleCompatibilityMatcher.match(
            candidate: candidate,
            video: video,
            samples: comparisonSamples
        )
    }

    private func speechProfile(for videoURL: URL) async throws -> SubtitleSpeechProfile {
        let key = SubtitleSpeechProfileKey(videoURL: videoURL)
        if let cached = cachedProfiles[key] { return cached }
        if let existingTask = profileTasks[key] {
            let profile = try await existingTask.value
            try Task.checkCancellation()
            return profile
        }

        let task = Task.detached(priority: .userInitiated) {
            try await SubtitleSpeechProfileExtractor.extract(from: videoURL)
        }
        profileTasks[key] = task

        do {
            let profile = try await task.value
            profileTasks[key] = nil
            cachedProfiles[key] = profile
            if cachedProfiles.count > 3,
               let oldestKey = cachedProfiles.keys.first(where: { $0 != key }) {
                cachedProfiles[oldestKey] = nil
            }
            try Task.checkCancellation()
            return profile
        } catch {
            profileTasks[key] = nil
            throw error
        }
    }
}

private struct SubtitleSpeechProfileKey: Hashable, Sendable {
    let url: URL
    let fileSize: Int?
    let modificationDate: Date?

    init(videoURL: URL) {
        url = videoURL.standardizedFileURL
        let values = try? videoURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        fileSize = values?.fileSize
        modificationDate = values?.contentModificationDate
    }
}

struct SubtitleSpeechSample: Sendable {
    let time: TimeInterval
    let probability: Double
}

private struct SubtitleSpeechProfile: Sendable {
    let samples: [SubtitleSpeechSample]

    func distributedDialogueSamples(videoDuration: TimeInterval?) -> [SubtitleSpeechSample] {
        guard !samples.isEmpty else { return [] }
        let inferredDuration = samples.last?.time ?? 0
        let duration = max(videoDuration ?? inferredDuration, inferredDuration)
        guard duration > 30 else { return samples }

        let bucketCount = 7
        let windowLength = min(105.0, max(45.0, duration / 45.0))
        var selected: [SubtitleSpeechSample] = []

        for bucketIndex in 0..<bucketCount {
            let bucketStart = duration * Double(bucketIndex) / Double(bucketCount)
            let bucketEnd = duration * Double(bucketIndex + 1) / Double(bucketCount)
            let usableStart = max(0, bucketStart)
            let usableEnd = min(duration, bucketEnd)
            guard usableEnd > usableStart else { continue }

            let candidateStarts: [TimeInterval]
            if usableEnd - usableStart <= windowLength {
                candidateStarts = [usableStart]
            } else {
                let latestStart = usableEnd - windowLength
                let step = max(15, (latestStart - usableStart) / 5)
                candidateStarts = stride(
                    from: usableStart,
                    through: latestStart + 0.001,
                    by: step
                ).map { $0 }
            }

            var bestWindow: [SubtitleSpeechSample] = []
            var bestScore = -Double.infinity
            for start in candidateStarts {
                let end = min(start + windowLength, duration)
                let window = samples.filter { $0.time >= start && $0.time <= end }
                guard window.count >= 20 else { continue }

                let values = window.map(\.probability)
                let mean = values.reduce(0, +) / Double(values.count)
                let variance = values.reduce(0) { partial, value in
                    partial + (value - mean) * (value - mean)
                } / Double(values.count)
                let speechDuty = Double(values.filter { $0 >= 0.25 }.count) / Double(values.count)
                let mixedDuty = min(speechDuty, 1 - speechDuty)
                let score = variance * 2.4 + mixedDuty * 0.7 + mean * 0.12
                if score > bestScore {
                    bestScore = score
                    bestWindow = window
                }
            }
            selected.append(contentsOf: bestWindow)
        }

        var seenTimes: Set<Int64> = []
        return selected
            .sorted { $0.time < $1.time }
            .filter { sample in
                seenTimes.insert(Int64((sample.time * 1_000).rounded())).inserted
            }
    }
}

private final class SubtitleSpeechObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [SubtitleSpeechSample] = []
    private var recordedError: Error?

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let probability = result.classification(forIdentifier: "speech")?.confidence ?? 0
        let midpoint = result.timeRange.start.seconds + result.timeRange.duration.seconds / 2
        guard midpoint.isFinite, probability.isFinite else { return }
        lock.lock()
        collected.append(SubtitleSpeechSample(
            time: midpoint,
            probability: min(max(probability, 0), 1)
        ))
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock()
        recordedError = error
        lock.unlock()
    }

    func snapshot() -> (samples: [SubtitleSpeechSample], error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (collected.sorted { $0.time < $1.time }, recordedError)
    }
}

private enum SubtitleSpeechProfileExtractor {
    static func extract(from videoURL: URL) async throws -> SubtitleSpeechProfile {
        let request: SNClassifySoundRequest
        let analyzer: SNAudioFileAnalyzer
        do {
            request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1_000)
            request.overlapFactor = 0
            analyzer = try SNAudioFileAnalyzer(url: videoURL)
        } catch {
            throw SubtitleCompatibilityError.audioAnalysisFailed(error.localizedDescription)
        }

        let observer = SubtitleSpeechObserver()
        do {
            try analyzer.add(request, withObserver: observer)
        } catch {
            throw SubtitleCompatibilityError.audioAnalysisFailed(error.localizedDescription)
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                analyzer.analyze { didReachEndOfFile in
                    let snapshot = observer.snapshot()
                    if let error = snapshot.error {
                        continuation.resume(
                            throwing: SubtitleCompatibilityError.audioAnalysisFailed(
                                error.localizedDescription
                            )
                        )
                    } else if !didReachEndOfFile {
                        continuation.resume(throwing: SubtitleCompatibilityError.audioAnalysisCancelled)
                    } else if snapshot.samples.count < 30 {
                        continuation.resume(throwing: SubtitleCompatibilityError.insufficientAudio)
                    } else {
                        continuation.resume(returning: SubtitleSpeechProfile(samples: snapshot.samples))
                    }
                }
            }
        }, onCancel: {
            analyzer.cancelAnalysis()
        })
    }
}

enum SubtitleCompatibilityMatcher {
    private struct Correction {
        let score: Double
        let videoPerSubtitleRate: Double
        let videoShift: TimeInterval
    }

    static func match(
        candidate: SubtitleCandidate,
        video: SubtitleSearchVideo,
        samples: [SubtitleSpeechSample]
    ) -> SubtitleSearchMatch {
        let cues = candidate.cues.filter(isLikelyDialogueCue)
        guard cues.count >= 8, samples.count >= 80 else {
            return SubtitleSearchMatch(
                candidate: candidate,
                verdict: .unverified,
                timingTransform: nil,
                audioMatchScore: nil,
                confidence: min(candidate.score.totalScore * 0.55, 0.49)
            )
        }

        let identityScore = correlationScore(
            samples: samples,
            cues: cues,
            videoPerSubtitleRate: 1,
            videoShift: 0
        )
        var best = Correction(score: identityScore, videoPerSubtitleRate: 1, videoShift: 0)

        var coarseRates = stride(from: 0.95, through: 1.050_001, by: 0.002).map { $0 }
        coarseRates.append(contentsOf: [
            24.0 / 25.0,
            (24_000.0 / 1_001.0) / 24.0,
            1.0,
            24.0 / (24_000.0 / 1_001.0),
            25.0 / 24.0,
            25.0 / (24_000.0 / 1_001.0)
        ])
        coarseRates = Array(Set(coarseRates.map { Int(($0 * 1_000_000).rounded()) }))
            .map { Double($0) / 1_000_000 }
            .sorted()

        for rate in coarseRates {
            for shiftStep in -90...90 {
                let shift = Double(shiftStep)
                let score = correlationScore(
                    samples: samples,
                    cues: cues,
                    videoPerSubtitleRate: rate,
                    videoShift: shift
                )
                if score > best.score {
                    best = Correction(score: score, videoPerSubtitleRate: rate, videoShift: shift)
                }
            }
        }

        let refinedRateStart = max(0.94, best.videoPerSubtitleRate - 0.003)
        let refinedRateEnd = min(1.06, best.videoPerSubtitleRate + 0.003)
        let refinedShiftStart = best.videoShift - 3
        let refinedShiftEnd = best.videoShift + 3
        for rate in stride(from: refinedRateStart, through: refinedRateEnd + 0.000_001, by: 0.000_1) {
            for shift in stride(from: refinedShiftStart, through: refinedShiftEnd + 0.001, by: 0.1) {
                let score = correlationScore(
                    samples: samples,
                    cues: cues,
                    videoPerSubtitleRate: rate,
                    videoShift: shift
                )
                if score > best.score {
                    best = Correction(score: score, videoPerSubtitleRate: rate, videoShift: shift)
                }
            }
        }

        let duration = video.duration ?? candidate.lastCueEnd ?? 0
        let accumulatedDrift = abs(best.videoPerSubtitleRate - 1) * max(duration, 0)
        let endingShift = best.videoShift
            + (best.videoPerSubtitleRate - 1) * max(candidate.lastCueEnd ?? duration, 0)
        let maximumCorrection = max(abs(best.videoShift), abs(endingShift))
        let improvement = best.score - identityScore
        let scoreConfidence = clamp((best.score - 0.12) / 0.34)
        let correctionConfidence = maximumCorrection < 0.8
            ? 1
            : clamp(improvement / 0.10)
        let confidence = clamp(scoreConfidence * 0.82 + correctionConfidence * 0.18)

        guard best.score >= 0.12 else {
            return SubtitleSearchMatch(
                candidate: candidate,
                verdict: candidate.score.confidence == .strong ? .differentEdit : .unverified,
                timingTransform: nil,
                audioMatchScore: max(best.score, 0),
                confidence: max(confidence, 0.2)
            )
        }
        guard best.score >= 0.32, confidence >= 0.58 else {
            let looksLikeAnotherTitle = hasConflictingReleaseYear(
                videoURL: video.url,
                subtitleURL: candidate.url
            )
            return SubtitleSearchMatch(
                candidate: candidate,
                verdict: looksLikeAnotherTitle ? .differentEdit : .unverified,
                timingTransform: nil,
                audioMatchScore: max(best.score, 0),
                confidence: confidence
            )
        }

        let timingTransform = SubtitleTimingTransform(
            offset: -best.videoShift / best.videoPerSubtitleRate,
            rate: 1 / best.videoPerSubtitleRate
        )
        let verdict: SubtitleCompatibilityVerdict
        if maximumCorrection < 0.9 {
            verdict = .suitable
        } else if accumulatedDrift < 1.0 {
            verdict = .timeOffset(seconds: best.videoShift)
        } else {
            let videoFPS = video.frameRate
            let subtitleFPS = videoFPS.map { $0 * best.videoPerSubtitleRate }
            verdict = .frameRate(subtitleFPS: subtitleFPS, videoFPS: videoFPS)
        }

        return SubtitleSearchMatch(
            candidate: candidate,
            verdict: verdict,
            timingTransform: timingTransform,
            audioMatchScore: best.score,
            confidence: confidence
        )
    }

    static func sortsBefore(_ lhs: SubtitleSearchMatch, _ rhs: SubtitleSearchMatch) -> Bool {
        let leftPriority = priority(lhs.verdict)
        let rightPriority = priority(rhs.verdict)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.candidate.score.totalScore != rhs.candidate.score.totalScore {
            return lhs.candidate.score.totalScore > rhs.candidate.score.totalScore
        }
        return lhs.candidate.url.path.localizedStandardCompare(rhs.candidate.url.path) == .orderedAscending
    }

    private static func priority(_ verdict: SubtitleCompatibilityVerdict) -> Int {
        switch verdict {
        case .suitable: return 0
        case .timeOffset: return 1
        case .frameRate: return 2
        case .unverified: return 3
        case .differentEdit: return 4
        }
    }

    private static func correlationScore(
        samples: [SubtitleSpeechSample],
        cues: [SubtitleCue],
        videoPerSubtitleRate: Double,
        videoShift: TimeInterval
    ) -> Double {
        guard videoPerSubtitleRate.isFinite, videoPerSubtitleRate > 0 else { return -1 }
        var sumAudio = 0.0
        var sumSubtitle = 0.0
        var sumAudioSquared = 0.0
        var sumSubtitleSquared = 0.0
        var sumProduct = 0.0

        for sample in samples {
            let subtitleTime = (sample.time - videoShift) / videoPerSubtitleRate
            let subtitleActive = cueIsActive(cues, at: subtitleTime) ? 1.0 : 0.0
            sumAudio += sample.probability
            sumSubtitle += subtitleActive
            sumAudioSquared += sample.probability * sample.probability
            sumSubtitleSquared += subtitleActive * subtitleActive
            sumProduct += sample.probability * subtitleActive
        }

        let count = Double(samples.count)
        let numerator = count * sumProduct - sumAudio * sumSubtitle
        let audioVariance = count * sumAudioSquared - sumAudio * sumAudio
        let subtitleVariance = count * sumSubtitleSquared - sumSubtitle * sumSubtitle
        let denominator = sqrt(max(audioVariance * subtitleVariance, 0))
        return denominator > 0 ? numerator / denominator : -1
    }

    private static func cueIsActive(_ cues: [SubtitleCue], at time: TimeInterval) -> Bool {
        var low = 0
        var high = cues.count - 1
        var candidate = -1
        while low <= high {
            let middle = (low + high) >> 1
            if cues[middle].start <= time {
                candidate = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard candidate >= 0 else { return false }
        for index in stride(from: candidate, through: max(0, candidate - 10), by: -1) {
            if cues[index].end >= time { return true }
        }
        return false
    }

    private static func isLikelyDialogueCue(_ cue: SubtitleCue) -> Bool {
        let duration = cue.end - cue.start
        guard duration >= 0.1, duration <= 18 else { return false }
        let trimmed = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("♪") || trimmed.contains("♫") { return false }
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) {
            return false
        }
        return trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func hasConflictingReleaseYear(videoURL: URL, subtitleURL: URL) -> Bool {
        func years(in url: URL) -> Set<Int> {
            let name = url.deletingPathExtension().lastPathComponent
            let expression = try? NSRegularExpression(pattern: #"(?<!\d)(?:18|19|20|21)\d{2}(?!\d)"#)
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return Set((expression?.matches(in: name, range: range) ?? []).compactMap { match in
                guard let swiftRange = Range(match.range, in: name) else { return nil }
                return Int(name[swiftRange])
            })
        }

        let videoYears = years(in: videoURL)
        let subtitleYears = years(in: subtitleURL)
        return !videoYears.isEmpty
            && !subtitleYears.isEmpty
            && videoYears.isDisjoint(with: subtitleYears)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}
