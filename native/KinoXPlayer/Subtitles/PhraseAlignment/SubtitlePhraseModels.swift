import Foundation

struct SubtitleFragmentID: Hashable, Codable, Sendable {
    let cueIndex: Int
    let fragmentIndex: Int

    init(cueIndex: Int, fragmentIndex: Int) {
        self.cueIndex = max(cueIndex, 0)
        self.fragmentIndex = max(fragmentIndex, 0)
    }
}

struct SubtitlePhraseFragment: Equatable, Hashable, Codable, Sendable {
    let id: SubtitleFragmentID
    let text: String
    let videoStart: TimeInterval
    let videoEnd: TimeInterval
    let endsSentence: Bool
    let startsNewSpeaker: Bool
    let isNonDialogue: Bool
    let characterWeight: Int

    init(
        id: SubtitleFragmentID,
        text: String,
        videoStart: TimeInterval,
        videoEnd: TimeInterval,
        endsSentence: Bool,
        startsNewSpeaker: Bool,
        isNonDialogue: Bool,
        characterWeight: Int
    ) {
        self.id = id
        self.text = text
        self.videoStart = videoStart.isFinite ? videoStart : 0
        self.videoEnd = videoEnd.isFinite
            ? max(videoEnd, self.videoStart)
            : self.videoStart
        self.endsSentence = endsSentence
        self.startsNewSpeaker = startsNewSpeaker
        self.isNonDialogue = isNonDialogue
        self.characterWeight = max(characterWeight, 1)
    }

    var duration: TimeInterval {
        max(videoEnd - videoStart, 0)
    }

    var isShortUtterance: Bool {
        let meaningfulCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                count += 1
            }
        }
        return meaningfulCount <= 4
    }
}

struct AlignedSubtitlePhrase: Equatable, Codable, Sendable {
    let primaryFragmentIDs: [SubtitleFragmentID]
    let secondaryFragmentIDs: [SubtitleFragmentID]
    let primaryText: String
    let secondaryText: String
    /// Paired subtitles are displayed on this S1-anchored interval.
    let videoStart: TimeInterval
    let videoEnd: TimeInterval
    let secondaryVideoStart: TimeInterval
    let secondaryVideoEnd: TimeInterval
    let semanticScore: Double
    let timingScore: Double
    let boundaryScore: Double
    let structureScore: Double
    let confidence: Double

    var isShortUtterance: Bool {
        Self.meaningfulCharacterCount(in: primaryText) <= 4
            || Self.meaningfulCharacterCount(in: secondaryText) <= 4
    }

    private static func meaningfulCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                count += 1
            }
        }
    }
}

struct SubtitlePhraseAlignmentSummary: Equatable, Codable, Sendable {
    let primaryFragmentCount: Int
    let secondaryFragmentCount: Int
    let alignedPrimaryFragmentCount: Int
    let alignedSecondaryFragmentCount: Int
    let pairCount: Int
    let coverage: Double
    let meanConfidence: Double

    var coveragePercent: Int {
        Int((coverage * 100).rounded())
    }
}

enum SubtitlePhraseAlignmentState: Equatable, Sendable {
    case idle
    case waitingForTracks
    case waitingForSynchronization
    case unavailable(String)
    case analyzing
    case aligned(SubtitlePhraseAlignmentSummary)
    case failed(String)
}

struct SubtitleDisplayFrame: Equatable, Sendable {
    let primaryText: String
    let secondaryText: String
    let isAlignedPair: Bool
    let confidence: Double?

    static let empty = SubtitleDisplayFrame(
        primaryText: "",
        secondaryText: "",
        isAlignedPair: false,
        confidence: nil
    )

    var isEmpty: Bool {
        primaryText.isEmpty && secondaryText.isEmpty
    }

    /// A linked pair is deliberately exposed as one VoiceOver label.
    var accessibilityText: String {
        [secondaryText, primaryText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct SubtitlePhraseAlignment: Equatable, Sendable {
    static let algorithmVersion = "phrase-alignment-v3"

    /// Standalone S2 is useful only when there is enough uncovered time to
    /// read it. Slight timing differences between tracks can otherwise expose
    /// the last few milliseconds of an unrelated S2 fragment after S1 ends.
    private static let minimumStandaloneSecondaryDisplayDuration: TimeInterval = 0.75

    let primaryFragments: [SubtitlePhraseFragment]
    let secondaryFragments: [SubtitlePhraseFragment]
    let alignedPhrases: [AlignedSubtitlePhrase]
    let unmatchedPrimaryFragments: [SubtitlePhraseFragment]
    let unmatchedSecondaryFragments: [SubtitlePhraseFragment]
    let summary: SubtitlePhraseAlignmentSummary
    let modelVersion: String

    private let displayEntries: [SubtitleDisplayEntry]
    private let prefixMaximumEndTimes: [TimeInterval]

    init(
        primaryFragments: [SubtitlePhraseFragment],
        secondaryFragments: [SubtitlePhraseFragment],
        alignedPhrases: [AlignedSubtitlePhrase],
        modelVersion: String
    ) {
        self.primaryFragments = primaryFragments
        self.secondaryFragments = secondaryFragments
        self.alignedPhrases = alignedPhrases.sorted {
            if $0.videoStart == $1.videoStart {
                return $0.confidence > $1.confidence
            }
            return $0.videoStart < $1.videoStart
        }
        self.modelVersion = modelVersion

        let pairedPrimaryIDs = Set(alignedPhrases.flatMap(\.primaryFragmentIDs))
        let pairedSecondaryIDs = Set(alignedPhrases.flatMap(\.secondaryFragmentIDs))
        unmatchedPrimaryFragments = primaryFragments.filter {
            !pairedPrimaryIDs.contains($0.id)
        }
        unmatchedSecondaryFragments = secondaryFragments.filter {
            !pairedSecondaryIDs.contains($0.id)
        }

        let alignedPrimaryCount = pairedPrimaryIDs.count
        let alignedSecondaryCount = pairedSecondaryIDs.count
        let totalCount = primaryFragments.count + secondaryFragments.count
        let coverage = totalCount > 0
            ? Double(alignedPrimaryCount + alignedSecondaryCount) / Double(totalCount)
            : 0
        let meanConfidence = alignedPhrases.isEmpty
            ? 0
            : alignedPhrases.map(\.confidence).reduce(0, +) / Double(alignedPhrases.count)
        summary = SubtitlePhraseAlignmentSummary(
            primaryFragmentCount: primaryFragments.count,
            secondaryFragmentCount: secondaryFragments.count,
            alignedPrimaryFragmentCount: alignedPrimaryCount,
            alignedSecondaryFragmentCount: alignedSecondaryCount,
            pairCount: alignedPhrases.count,
            coverage: coverage,
            meanConfidence: meanConfidence
        )

        let primaryCoverage = Self.mergedCoverageIntervals(
            for: primaryFragments,
            alignedPhrases: alignedPhrases
        )
        var entries = alignedPhrases.map(SubtitleDisplayEntry.pair)
        entries.append(contentsOf: unmatchedPrimaryFragments.map(SubtitleDisplayEntry.primary))
        entries.append(contentsOf: unmatchedSecondaryFragments.flatMap { fragment in
            Self.readableStandaloneSecondaryEntries(
                for: fragment,
                excluding: primaryCoverage
            )
        })
        entries.sort {
            if $0.videoStart == $1.videoStart {
                return $0.kind.sortPriority < $1.kind.sortPriority
            }
            return $0.videoStart < $1.videoStart
        }
        displayEntries = entries

        var maximumEnd = -Double.infinity
        prefixMaximumEndTimes = entries.map { entry in
            maximumEnd = max(maximumEnd, entry.videoEnd)
            return maximumEnd
        }
    }

    /// Returns a context-safe display frame without scanning the whole movie.
    /// An unmatched S1 wins over an overlapping pair, and standalone S2 is only
    /// returned when no primary phrase is active.
    func displayFrame(at playbackTime: TimeInterval) -> SubtitleDisplayFrame {
        guard playbackTime.isFinite, !displayEntries.isEmpty else { return .empty }

        var low = 0
        var high = displayEntries.count
        while low < high {
            let middle = (low + high) / 2
            if displayEntries[middle].videoStart <= playbackTime {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var activePairs: [SubtitleDisplayEntry] = []
        var activePrimary: [SubtitleDisplayEntry] = []
        var activeSecondary: [SubtitleDisplayEntry] = []
        var index = low - 1
        while index >= 0, prefixMaximumEndTimes[index] > playbackTime {
            let entry = displayEntries[index]
            if entry.videoStart <= playbackTime, entry.videoEnd > playbackTime {
                switch entry.kind {
                case .pair:
                    activePairs.append(entry)
                case .primary:
                    activePrimary.append(entry)
                case .secondary:
                    activeSecondary.append(entry)
                }
            }
            index -= 1
        }

        // An unmatched S1 line wins over every overlapping pair. This is the
        // conservative choice for overlapping cues: never expose S2 while an
        // active primary phrase has not itself been context-verified.
        if !activePrimary.isEmpty {
            return SubtitleDisplayFrame(
                primaryText: Self.joinActiveTexts(activePrimary),
                secondaryText: "",
                isAlignedPair: false,
                confidence: nil
            )
        }

        if let pair = activePairs.max(by: { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                return lhs.videoStart > rhs.videoStart
            }
            return (lhs.confidence ?? 0) < (rhs.confidence ?? 0)
        }) {
            return SubtitleDisplayFrame(
                primaryText: pair.primaryText,
                secondaryText: pair.secondaryText,
                isAlignedPair: true,
                confidence: pair.confidence
            )
        }

        if !activeSecondary.isEmpty {
            return SubtitleDisplayFrame(
                primaryText: "",
                secondaryText: Self.joinActiveTexts(activeSecondary),
                isAlignedPair: false,
                confidence: nil
            )
        }

        return .empty
    }

    private static func joinActiveTexts(_ entries: [SubtitleDisplayEntry]) -> String {
        var seen: Set<String> = []
        return entries
            .sorted { $0.videoStart < $1.videoStart }
            .map(\.standaloneText)
            .filter { seen.insert($0).inserted }
            .joined(separator: "\n")
    }

    private static func mergedCoverageIntervals(
        for fragments: [SubtitlePhraseFragment],
        alignedPhrases: [AlignedSubtitlePhrase]
    ) -> [SubtitleTimeInterval] {
        let fragmentIntervals = fragments
            .filter { $0.videoEnd > $0.videoStart }
            .map { SubtitleTimeInterval(start: $0.videoStart, end: $0.videoEnd) }

        let pairIntervals = alignedPhrases
            .filter { $0.videoEnd > $0.videoStart }
            .map { SubtitleTimeInterval(start: $0.videoStart, end: $0.videoEnd) }

        let sorted = (fragmentIntervals + pairIntervals)
            .sorted {
                if $0.start == $1.start { return $0.end < $1.end }
                return $0.start < $1.start
            }

        var merged: [SubtitleTimeInterval] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = SubtitleTimeInterval(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func readableStandaloneSecondaryEntries(
        for fragment: SubtitlePhraseFragment,
        excluding primaryCoverage: [SubtitleTimeInterval]
    ) -> [SubtitleDisplayEntry] {
        guard fragment.videoEnd > fragment.videoStart else { return [] }

        var cursor = fragment.videoStart
        var coverageIndex = firstCoverageEnding(
            after: cursor,
            in: primaryCoverage
        )
        var visibleIntervals: [SubtitleTimeInterval] = []
        var wasClippedByPrimary = false

        while coverageIndex < primaryCoverage.count {
            let coverage = primaryCoverage[coverageIndex]
            guard coverage.start < fragment.videoEnd else { break }

            wasClippedByPrimary = true

            if coverage.start > cursor {
                visibleIntervals.append(SubtitleTimeInterval(
                    start: cursor,
                    end: min(coverage.start, fragment.videoEnd)
                ))
            }
            cursor = max(cursor, coverage.end)
            if cursor >= fragment.videoEnd { break }
            coverageIndex += 1
        }

        if cursor < fragment.videoEnd {
            visibleIntervals.append(SubtitleTimeInterval(
                start: cursor,
                end: fragment.videoEnd
            ))
        }

        return visibleIntervals
            .filter {
                !wasClippedByPrimary
                    || $0.end - $0.start >= minimumStandaloneSecondaryDisplayDuration
            }
            .map {
                SubtitleDisplayEntry.secondary(
                    fragment,
                    videoStart: $0.start,
                    videoEnd: $0.end
                )
            }
    }

    private static func firstCoverageEnding(
        after time: TimeInterval,
        in intervals: [SubtitleTimeInterval]
    ) -> Int {
        var low = 0
        var high = intervals.count
        while low < high {
            let middle = (low + high) / 2
            if intervals[middle].end <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

private struct SubtitleTimeInterval: Sendable {
    let start: TimeInterval
    let end: TimeInterval
}

private struct SubtitleDisplayEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case pair
        case primary
        case secondary

        var sortPriority: Int {
            switch self {
            case .pair: return 0
            case .primary: return 1
            case .secondary: return 2
            }
        }
    }

    let kind: Kind
    let videoStart: TimeInterval
    let videoEnd: TimeInterval
    let primaryText: String
    let secondaryText: String
    let confidence: Double?

    var standaloneText: String {
        primaryText.isEmpty ? secondaryText : primaryText
    }

    static func pair(_ phrase: AlignedSubtitlePhrase) -> SubtitleDisplayEntry {
        SubtitleDisplayEntry(
            kind: .pair,
            videoStart: phrase.videoStart,
            videoEnd: phrase.videoEnd,
            primaryText: phrase.primaryText,
            secondaryText: phrase.secondaryText,
            confidence: phrase.confidence
        )
    }

    static func primary(_ fragment: SubtitlePhraseFragment) -> SubtitleDisplayEntry {
        SubtitleDisplayEntry(
            kind: .primary,
            videoStart: fragment.videoStart,
            videoEnd: fragment.videoEnd,
            primaryText: fragment.text,
            secondaryText: "",
            confidence: nil
        )
    }

    static func secondary(
        _ fragment: SubtitlePhraseFragment,
        videoStart: TimeInterval,
        videoEnd: TimeInterval
    ) -> SubtitleDisplayEntry {
        SubtitleDisplayEntry(
            kind: .secondary,
            videoStart: videoStart,
            videoEnd: videoEnd,
            primaryText: "",
            secondaryText: fragment.text,
            confidence: nil
        )
    }
}
