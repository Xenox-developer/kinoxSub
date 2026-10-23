import Foundation

/// Affine mapping from playback time to the candidate subtitle timeline:
/// `subtitleTime = offset + rate * videoTime`.
struct SubtitleTimingTransform: Equatable, Hashable, Sendable {
    let offset: TimeInterval
    let rate: Double

    init(offset: TimeInterval, rate: Double = 1) {
        self.offset = offset.isFinite ? offset : 0
        self.rate = rate.isFinite && rate > 0 ? rate : 1
    }

    func subtitleTime(forVideoTime videoTime: TimeInterval) -> TimeInterval {
        offset + rate * videoTime
    }

    func videoTime(forSubtitleTime subtitleTime: TimeInterval) -> TimeInterval {
        (subtitleTime - offset) / rate
    }

    var driftPerHour: TimeInterval {
        (rate - 1) * 3_600
    }

    static let identity = SubtitleTimingTransform(offset: 0, rate: 1)
}

struct SubtitleAudioAnalysis: Equatable, Sendable {
    let matchScore: Double
    let confidence: Double
    let timingTransform: SubtitleTimingTransform?
    let analyzedSampleCount: Int

    init(
        matchScore: Double,
        confidence: Double,
        timingTransform: SubtitleTimingTransform?,
        analyzedSampleCount: Int
    ) {
        self.matchScore = min(max(matchScore.isFinite ? matchScore : 0, 0), 1)
        self.confidence = min(max(confidence.isFinite ? confidence : 0, 0), 1)
        self.timingTransform = timingTransform
        self.analyzedSampleCount = max(analyzedSampleCount, 0)
    }
}

/// Extension point for a future local speech/VAD analyzer. Implementations may use
/// AVFoundation, Speech, Whisper, or another on-device engine without coupling it
/// to folder discovery and metadata scoring.
protocol SubtitleAudioAnalyzing: Sendable {
    func analyze(
        video: SubtitleSearchVideo,
        candidate: SubtitleCandidate
    ) async throws -> SubtitleAudioAnalysis
}
