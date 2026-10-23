import Foundation

enum SubtitleFileFormat: String, CaseIterable, Sendable {
    case srt
    case webVTT = "vtt"

    init?(fileURL: URL) {
        self.init(rawValue: fileURL.pathExtension.lowercased())
    }
}

struct SubtitleSearchVideo: Equatable, Sendable {
    let url: URL
    let duration: TimeInterval?
    let frameRate: Double?

    init(url: URL, duration: TimeInterval?, frameRate: Double? = nil) {
        self.url = url
        if let duration, duration.isFinite, duration > 0 {
            self.duration = duration
        } else {
            self.duration = nil
        }
        if let frameRate, frameRate.isFinite, frameRate > 0 {
            self.frameRate = frameRate
        } else {
            self.frameRate = nil
        }
    }
}

enum SubtitleMatchConfidence: String, Comparable, Sendable {
    case weak
    case plausible
    case strong

    private var rank: Int {
        switch self {
        case .weak: return 0
        case .plausible: return 1
        case .strong: return 2
        }
    }

    static func < (lhs: SubtitleMatchConfidence, rhs: SubtitleMatchConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

struct SubtitleMatchScore: Equatable, Sendable {
    let totalScore: Double
    let fileNameScore: Double
    let durationScore: Double?
    let timelineScore: Double

    var confidence: SubtitleMatchConfidence {
        if totalScore >= 0.78 { return .strong }
        if totalScore >= 0.50 { return .plausible }
        return .weak
    }
}

struct SubtitleCandidate: Identifiable, Equatable, Sendable {
    let url: URL
    let format: SubtitleFileFormat
    let encodingName: String
    let cues: [SubtitleCue]
    let fileSizeBytes: Int
    let score: SubtitleMatchScore

    var id: URL { url.standardizedFileURL }
    var cueCount: Int { cues.count }
    var firstCueStart: TimeInterval? { cues.first?.start }
    var lastCueEnd: TimeInterval? { cues.last?.end }
}

struct SubtitleSearchOptions: Equatable, Sendable {
    var recursive: Bool
    var maxCandidateFiles: Int
    var maxFileSizeBytes: Int

    init(
        recursive: Bool = false,
        maxCandidateFiles: Int = 250,
        maxFileSizeBytes: Int = 16 * 1_024 * 1_024
    ) {
        self.recursive = recursive
        self.maxCandidateFiles = min(max(maxCandidateFiles, 1), 2_000)
        self.maxFileSizeBytes = max(maxFileSizeBytes, 1)
    }
}

enum SubtitleCandidateRejectionReason: Equatable, Sendable {
    case tooLarge(actualBytes: Int, limitBytes: Int)
    case unreadable(String)
    case noCues
    case parsingFailed(String)
}

struct RejectedSubtitleCandidate: Identifiable, Equatable, Sendable {
    let url: URL
    let reason: SubtitleCandidateRejectionReason

    var id: URL { url.standardizedFileURL }
}

struct SubtitleSearchResult: Equatable, Sendable {
    let candidates: [SubtitleCandidate]
    let rejectedCandidates: [RejectedSubtitleCandidate]
    let wasTruncated: Bool
}

enum LocalSubtitleSearchError: LocalizedError, Equatable {
    case folderDoesNotExist(URL)
    case selectedURLIsNotFolder(URL)
    case unableToEnumerate(URL, String)

    var errorDescription: String? {
        switch self {
        case .folderDoesNotExist(let url):
            return "Папка не найдена: \(url.path)"
        case .selectedURLIsNotFolder(let url):
            return "Выбранный путь не является папкой: \(url.path)"
        case .unableToEnumerate(let url, let message):
            return "Не удалось просмотреть папку \(url.path): \(message)"
        }
    }
}
