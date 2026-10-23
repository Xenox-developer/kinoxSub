import Foundation
import NaturalLanguage

struct SubtitlePhraseFragmenter: Sendable {
    static let maximumFragmentsPerCue = 6
    static let minimumVirtualDuration: TimeInterval = 0.4

    func fragments(
        from cues: [SubtitleCue],
        timingTransform: SubtitleTimingTransform = .identity,
        manualOffset: TimeInterval = 0,
        languageCode: String? = nil
    ) -> [SubtitlePhraseFragment] {
        var result: [SubtitlePhraseFragment] = []
        result.reserveCapacity(cues.count)

        for (cueIndex, cue) in cues.enumerated() {
            let pieces = sentencePieces(in: cue.text, languageCode: languageCode)
            guard !pieces.isEmpty else { continue }

            let cueVideoStart = timingTransform.videoTime(forSubtitleTime: cue.start)
                + (manualOffset.isFinite ? manualOffset : 0)
            let cueVideoEnd = timingTransform.videoTime(forSubtitleTime: cue.end)
                + (manualOffset.isFinite ? manualOffset : 0)
            let start = min(cueVideoStart, cueVideoEnd)
            let end = max(cueVideoStart, cueVideoEnd)
            let weights = pieces.map { characterWeight(for: $0.text) }
            let durations = allocatedDurations(
                weights: weights,
                availableDuration: max(end - start, 0)
            )

            var fragmentStart = start
            for (fragmentIndex, piece) in pieces.enumerated() {
                let fragmentEnd: TimeInterval
                if fragmentIndex == pieces.count - 1 {
                    fragmentEnd = end
                } else {
                    fragmentEnd = min(fragmentStart + durations[fragmentIndex], end)
                }

                result.append(SubtitlePhraseFragment(
                    id: SubtitleFragmentID(
                        cueIndex: cueIndex,
                        fragmentIndex: fragmentIndex
                    ),
                    text: piece.text,
                    videoStart: fragmentStart,
                    videoEnd: max(fragmentEnd, fragmentStart),
                    endsSentence: Self.hasStrongEnding(piece.text),
                    startsNewSpeaker: piece.startsNewSpeaker,
                    // Overflow fragments can contain multiple contexts. They
                    // remain visible as standalone text but are excluded from
                    // semantic pairing instead of risking a mixed translation.
                    isNonDialogue: piece.forceUnpaired
                        || Self.isNonDialogue(piece.text),
                    characterWeight: weights[fragmentIndex]
                ))
                fragmentStart = fragmentEnd
            }
        }

        return result.sorted {
            if $0.videoStart == $1.videoStart {
                if $0.id.cueIndex == $1.id.cueIndex {
                    return $0.id.fragmentIndex < $1.id.fragmentIndex
                }
                return $0.id.cueIndex < $1.id.cueIndex
            }
            return $0.videoStart < $1.videoStart
        }
    }

    private func sentencePieces(
        in source: String,
        languageCode: String?
    ) -> [SentencePiece] {
        let blocks = speakerBlocks(in: source)
        var pieces: [SentencePiece] = []

        for block in blocks {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = block.text
            if let languageCode, !languageCode.isEmpty {
                tokenizer.setLanguage(NLLanguage(rawValue: languageCode))
            }

            var blockPieces: [SentencePiece] = []
            tokenizer.enumerateTokens(
                in: block.text.startIndex..<block.text.endIndex
            ) { range, _ in
                let text = Self.normalizedDisplayText(String(block.text[range]))
                if !text.isEmpty {
                    blockPieces.append(SentencePiece(
                        text: text,
                        startsNewSpeaker: block.startsNewSpeaker && blockPieces.isEmpty,
                        forceUnpaired: block.forceUnpaired
                    ))
                }
                return true
            }

            if blockPieces.isEmpty {
                let text = Self.normalizedDisplayText(block.text)
                if !text.isEmpty {
                    blockPieces = [SentencePiece(
                        text: text,
                        startsNewSpeaker: block.startsNewSpeaker,
                        forceUnpaired: block.forceUnpaired
                    )]
                }
            }
            blockPieces = Self.rejoiningHonorificSplits(blockPieces)
            pieces.append(contentsOf: blockPieces)
        }

        guard pieces.count > Self.maximumFragmentsPerCue else { return pieces }
        let retainedCount = Self.maximumFragmentsPerCue - 1
        var limited = Array(pieces.prefix(retainedCount))
        let overflow = pieces.dropFirst(retainedCount)
        limited.append(SentencePiece(
            text: overflow.map(\.text).joined(separator: " "),
            startsNewSpeaker: overflow.first?.startsNewSpeaker ?? false,
            forceUnpaired: true
        ))
        return limited
    }

    private func speakerBlocks(in source: String) -> [SentencePiece] {
        let normalizedNewlines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedNewlines
            .components(separatedBy: "\n")
            .map(Self.normalizedDisplayText)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        var blocks: [SentencePiece] = []
        var current = ""
        var currentStartsSpeaker = false

        func flushCurrent() {
            guard !current.isEmpty else { return }
            blocks.append(SentencePiece(
                text: current,
                startsNewSpeaker: currentStartsSpeaker
            ))
            current = ""
            currentStartsSpeaker = false
        }

        for line in lines {
            let isStandaloneNonDialogue = Self.isStandaloneNonDialogueLine(line)
            let startsSpeaker = Self.hasSpeakerPrefix(line)
                || Self.hasNamedSpeakerPrefix(line)
            if isStandaloneNonDialogue {
                flushCurrent()
                blocks.append(SentencePiece(
                    text: line,
                    startsNewSpeaker: false,
                    forceUnpaired: true
                ))
                continue
            }
            if startsSpeaker {
                flushCurrent()
                current = line
                currentStartsSpeaker = true
            } else if current.isEmpty {
                current = line
            } else {
                current += " " + line
            }
        }
        flushCurrent()
        return blocks
    }

    private func allocatedDurations(
        weights: [Int],
        availableDuration: TimeInterval
    ) -> [TimeInterval] {
        guard !weights.isEmpty else { return [] }
        guard availableDuration > 0 else {
            return Array(repeating: 0, count: weights.count)
        }

        let minimumTotal = Self.minimumVirtualDuration * Double(weights.count)
        if availableDuration < minimumTotal {
            return Array(
                repeating: availableDuration / Double(weights.count),
                count: weights.count
            )
        }

        let distributable = availableDuration - minimumTotal
        let totalWeight = Double(weights.reduce(0, +))
        return weights.map { weight in
            Self.minimumVirtualDuration
                + distributable * Double(weight) / max(totalWeight, 1)
        }
    }

    private func characterWeight(for text: String) -> Int {
        let count = text.unicodeScalars.reduce(into: 0) { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                result += 1
            }
        }
        return max(count, 1)
    }

    private static func normalizedDisplayText(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `NLTokenizer` can split `Mrs. Barish` after the period and turn the
    /// surname into a contextless fragment. Rejoin only well-known honorifics;
    /// ordinary sentence endings remain untouched.
    private static func rejoiningHonorificSplits(
        _ pieces: [SentencePiece]
    ) -> [SentencePiece] {
        guard pieces.count > 1 else { return pieces }
        var result: [SentencePiece] = []
        for piece in pieces {
            if let previous = result.last,
               endsWithHonorific(previous.text) {
                result[result.count - 1] = SentencePiece(
                    text: normalizedDisplayText(previous.text + " " + piece.text),
                    startsNewSpeaker: previous.startsNewSpeaker,
                    forceUnpaired: previous.forceUnpaired || piece.forceUnpaired
                )
            } else {
                result.append(piece)
            }
        }
        return result
    }

    private static func endsWithHonorific(_ text: String) -> Bool {
        guard let token = text
            .split(whereSeparator: { $0.isWhitespace })
            .last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”()[]{}"))
            .lowercased() else {
            return false
        }
        return ["mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr."].contains(token)
    }

    private static func hasSpeakerPrefix(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first == "-" || first == "–" || first == "—"
    }

    private static func hasNamedSpeakerPrefix(_ text: String) -> Bool {
        guard let colonIndex = text.firstIndex(of: ":") else { return false }
        let name = text[..<colonIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { return false }

        let words = name.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= 4 else { return false }

        let scalars = name.unicodeScalars
        guard scalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return false
        }
        guard !scalars.contains(where: { CharacterSet.lowercaseLetters.contains($0) }) else {
            return false
        }

        let allowedPunctuation = CharacterSet(charactersIn: " .'-’")
        return scalars.allSatisfy {
            CharacterSet.uppercaseLetters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || CharacterSet.whitespaces.contains($0)
                || allowedPunctuation.contains($0)
        }
    }

    private static func isStandaloneNonDialogueLine(_ text: String) -> Bool {
        let stripped = strippingSpeakerPrefix(from: text)
        return isNonDialogue(stripped)
    }

    private static func strippingSpeakerPrefix(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSpeakerPrefix(trimmed) else { return trimmed }
        return String(trimmed.dropFirst())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasStrongEnding(_ text: String) -> Bool {
        let endings = CharacterSet(charactersIn: ".!?…。！？")
        guard let scalar = text.unicodeScalars.last(where: {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet(charactersIn: "\"'»”)]}").contains($0)
        }) else {
            return false
        }
        return endings.contains(scalar)
    }

    private static func isNonDialogue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.contains("♪") || trimmed.contains("♫") || trimmed.contains("♬") {
            return true
        }

        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("{", "}")]
        if let first = trimmed.first, let last = trimmed.last,
           pairs.contains(where: { $0.0 == first && $0.1 == last }) {
            return true
        }
        return false
    }
}

private struct SentencePiece {
    let text: String
    let startsNewSpeaker: Bool
    let forceUnpaired: Bool

    init(
        text: String,
        startsNewSpeaker: Bool,
        forceUnpaired: Bool = false
    ) {
        self.text = text
        self.startsNewSpeaker = startsNewSpeaker
        self.forceUnpaired = forceUnpaired
    }
}
