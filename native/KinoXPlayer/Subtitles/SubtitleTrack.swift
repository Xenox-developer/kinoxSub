import Foundation

enum SubtitleSynchronizationState: Equatable, Sendable {
    case idle
    case analyzing
    case synchronized(confidence: Double?)
    case uncertain(String)
    case failed(String)
}

enum SubtitleSlot: String, CaseIterable, Hashable, Identifiable {
    case primary
    case secondary

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .primary: return "S1"
        case .secondary: return "S2"
        }
    }

    var title: String {
        switch self {
        case .primary: return "Основные субтитры"
        case .secondary: return "Вторые субтитры"
        }
    }
}

struct SubtitleTrack {
    let slot: SubtitleSlot
    var fileURL: URL?
    var fileName: String?
    var encodingName: String?
    var languageCode: String?
    var cues: [SubtitleCue] = []
    var isEnabled = true
    var offset: TimeInterval = 0
    var timingTransform: SubtitleTimingTransform = .identity
    var synchronizationState: SubtitleSynchronizationState = .idle
    var isLoading = false
    var errorMessage: String?

    var isLoaded: Bool { !cues.isEmpty }

    var hasAutomaticTimingCorrection: Bool {
        abs(automaticDisplayShift) >= 0.05 || abs(automaticDriftPerHour) >= 0.05
    }

    /// How much the automatic transform moves a cue at the beginning of the movie.
    /// A negative value means that the cue is displayed earlier.
    var automaticDisplayShift: TimeInterval {
        timingTransform.videoTime(forSubtitleTime: 0)
    }

    /// Change in the displayed correction over one hour of subtitle time.
    var automaticDriftPerHour: TimeInterval {
        timingTransform.videoTime(forSubtitleTime: 3_600)
            - timingTransform.videoTime(forSubtitleTime: 0)
            - 3_600
    }

    func activeText(at playbackTime: TimeInterval) -> String {
        guard isEnabled else { return "" }
        let subtitleTime = timingTransform.subtitleTime(
            forVideoTime: playbackTime - offset
        )
        return SubtitleParser.activeText(in: cues, at: subtitleTime)
    }
}
