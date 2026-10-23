import Foundation

struct SubtitlePhraseAlignmentConfiguration: Equatable, Sendable {
    var maximumGroupSize: Int
    var maximumGroupGap: TimeInterval
    var maximumGroupDuration: TimeInterval
    var maximumCandidateMidpointDistance: TimeInterval
    var minimumSemanticScore: Double
    var minimumConfidence: Double
    var semanticWeight: Double
    var timingWeight: Double
    var boundaryWeight: Double
    var structureWeight: Double
    var primarySkipPenalty: Double
    var secondarySkipPenalty: Double
    var mergePenalty: Double
    var imbalancePenalty: Double
    var embeddingBatchSize: Int
    var shortPhraseNeighborTime: TimeInterval
    var minimumOrderedFragmentCoverage: Double
    var minimumBidirectionalFragmentScore: Double
    var minimumShortPhraseSemanticScore: Double
    var minimumShortNeighborSemanticScore: Double
    var outsideEdgeCompetitionMargin: Double
    var microAlignmentGapPenalty: Double
    var singletonLocalBestBypassSemanticScore: Double
    var singletonLocalBestTolerance: Double

    init(
        maximumGroupSize: Int = 3,
        maximumGroupGap: TimeInterval = 2,
        maximumGroupDuration: TimeInterval = 15,
        maximumCandidateMidpointDistance: TimeInterval = 8,
        minimumSemanticScore: Double = 0.35,
        minimumConfidence: Double = 0.75,
        semanticWeight: Double = 0.48,
        timingWeight: Double = 0.32,
        boundaryWeight: Double = 0.12,
        structureWeight: Double = 0.08,
        primarySkipPenalty: Double = 0.12,
        secondarySkipPenalty: Double = 0.12,
        mergePenalty: Double = 0.08,
        imbalancePenalty: Double = 0.04,
        embeddingBatchSize: Int = 64,
        shortPhraseNeighborTime: TimeInterval = 12,
        minimumOrderedFragmentCoverage: Double = 0.50,
        minimumBidirectionalFragmentScore: Double = 0.45,
        minimumShortPhraseSemanticScore: Double = 0.84,
        minimumShortNeighborSemanticScore: Double = 0.65,
        outsideEdgeCompetitionMargin: Double = 0.12,
        microAlignmentGapPenalty: Double = 0.35,
        singletonLocalBestBypassSemanticScore: Double = 0.88,
        singletonLocalBestTolerance: Double = 0.01
    ) {
        self.maximumGroupSize = min(max(maximumGroupSize, 1), 3)
        self.maximumGroupGap = max(maximumGroupGap, 0)
        self.maximumGroupDuration = max(maximumGroupDuration, 0.4)
        self.maximumCandidateMidpointDistance = max(maximumCandidateMidpointDistance, 0.4)
        self.minimumSemanticScore = min(max(minimumSemanticScore, -1), 1)
        self.minimumConfidence = min(max(minimumConfidence, 0), 1)
        self.semanticWeight = max(semanticWeight, 0)
        self.timingWeight = max(timingWeight, 0)
        self.boundaryWeight = max(boundaryWeight, 0)
        self.structureWeight = max(structureWeight, 0)
        self.primarySkipPenalty = max(primarySkipPenalty, 0)
        self.secondarySkipPenalty = max(secondarySkipPenalty, 0)
        self.mergePenalty = max(mergePenalty, 0)
        self.imbalancePenalty = max(imbalancePenalty, 0)
        self.embeddingBatchSize = max(embeddingBatchSize, 1)
        self.shortPhraseNeighborTime = max(shortPhraseNeighborTime, 0)
        self.minimumOrderedFragmentCoverage = min(
            max(minimumOrderedFragmentCoverage, -1),
            1
        )
        self.minimumBidirectionalFragmentScore = min(
            max(minimumBidirectionalFragmentScore, -1),
            1
        )
        self.minimumShortPhraseSemanticScore = min(
            max(minimumShortPhraseSemanticScore, -1),
            1
        )
        self.minimumShortNeighborSemanticScore = min(
            max(minimumShortNeighborSemanticScore, -1),
            1
        )
        self.outsideEdgeCompetitionMargin = min(
            max(outsideEdgeCompetitionMargin, 0),
            2
        )
        self.microAlignmentGapPenalty = max(microAlignmentGapPenalty, 0)
        self.singletonLocalBestBypassSemanticScore = min(
            max(singletonLocalBestBypassSemanticScore, -1),
            1
        )
        self.singletonLocalBestTolerance = min(
            max(singletonLocalBestTolerance, 0),
            2
        )
    }
}

struct SubtitlePhraseAligner: Sendable {
    let embeddingProvider: any PhraseEmbeddingProviding
    let configuration: SubtitlePhraseAlignmentConfiguration

    init(
        embeddingProvider: any PhraseEmbeddingProviding,
        configuration: SubtitlePhraseAlignmentConfiguration = SubtitlePhraseAlignmentConfiguration()
    ) {
        self.embeddingProvider = embeddingProvider
        self.configuration = configuration
    }

    func align(
        primaryCues: [SubtitleCue],
        secondaryCues: [SubtitleCue],
        primaryTimingTransform: SubtitleTimingTransform = .identity,
        primaryManualOffset: TimeInterval = 0,
        secondaryTimingTransform: SubtitleTimingTransform = .identity,
        secondaryManualOffset: TimeInterval = 0,
        primaryLanguageCode: String? = nil,
        secondaryLanguageCode: String? = nil
    ) async throws -> SubtitlePhraseAlignment {
        let fragmenter = SubtitlePhraseFragmenter()
        let primary = fragmenter.fragments(
            from: primaryCues,
            timingTransform: primaryTimingTransform,
            manualOffset: primaryManualOffset,
            languageCode: primaryLanguageCode
        )
        let secondary = fragmenter.fragments(
            from: secondaryCues,
            timingTransform: secondaryTimingTransform,
            manualOffset: secondaryManualOffset,
            languageCode: secondaryLanguageCode
        )
        return try await align(primary: primary, secondary: secondary)
    }

    func align(
        primary: [SubtitlePhraseFragment],
        secondary: [SubtitlePhraseFragment]
    ) async throws -> SubtitlePhraseAlignment {
        try Task.checkCancellation()
        let modelVersion = embeddingProvider.modelVersion
        guard !primary.isEmpty, !secondary.isEmpty else {
            return SubtitlePhraseAlignment(
                primaryFragments: primary,
                secondaryFragments: secondary,
                alignedPhrases: [],
                modelVersion: modelVersion
            )
        }

        let allTexts = primary.map(\.text) + secondary.map(\.text)
        let embeddingLookup = try await loadEmbeddings(for: allTexts)
        try Task.checkCancellation()

        let engine = SubtitlePhraseAlignmentEngine(
            primary: primary,
            secondary: secondary,
            embeddingLookup: embeddingLookup,
            modelVersion: modelVersion,
            configuration: configuration
        )
        let worker = Task.detached(priority: .userInitiated) {
            try engine.run()
        }
        return try await withTaskCancellationHandler(
            operation: { try await worker.value },
            onCancel: { worker.cancel() }
        )
    }

    private func loadEmbeddings(for texts: [String]) async throws -> [String: [Float]] {
        var uniqueTexts: [String] = []
        var seen: Set<String> = []
        for text in texts {
            let normalized = Self.embeddingText(text)
            if seen.insert(normalized).inserted {
                uniqueTexts.append(normalized)
            }
        }

        var lookup: [String: [Float]] = [:]
        lookup.reserveCapacity(uniqueTexts.count)
        var expectedDimension: Int?

        for batchStart in stride(
            from: 0,
            to: uniqueTexts.count,
            by: configuration.embeddingBatchSize
        ) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + configuration.embeddingBatchSize, uniqueTexts.count)
            let batch = Array(uniqueTexts[batchStart..<batchEnd])
            let vectors = try await embeddingProvider.embeddings(for: batch)
            guard vectors.count == batch.count else {
                throw PhraseEmbeddingError.countMismatch(
                    expected: batch.count,
                    actual: vectors.count
                )
            }

            for (text, vector) in zip(batch, vectors) {
                guard !vector.isEmpty else { throw PhraseEmbeddingError.emptyVector }
                if let expectedDimension, vector.count != expectedDimension {
                    throw PhraseEmbeddingError.inconsistentDimensions
                }
                expectedDimension = vector.count
                lookup[text] = try Self.normalized(vector)
            }
        }
        return lookup
    }

    fileprivate static func embeddingText(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ vector: [Float]) throws -> [Float] {
        var squaredLength = 0.0
        for value in vector {
            guard value.isFinite else { throw PhraseEmbeddingError.nonFiniteValue }
            squaredLength += Double(value * value)
        }
        guard squaredLength.isFinite else { throw PhraseEmbeddingError.nonFiniteValue }
        let length = sqrt(squaredLength)
        guard length > Double.leastNonzeroMagnitude else {
            throw PhraseEmbeddingError.emptyVector
        }
        return vector.map { Float(Double($0) / length) }
    }
}

private struct SubtitlePhraseAlignmentEngine: Sendable {
    let primary: [SubtitlePhraseFragment]
    let secondary: [SubtitlePhraseFragment]
    let embeddingLookup: [String: [Float]]
    let modelVersion: String
    let configuration: SubtitlePhraseAlignmentConfiguration

    func run() throws -> SubtitlePhraseAlignment {
        let primaryGroups = try makeGroups(from: primary)
        let secondaryGroups = try makeGroups(from: secondary)
        var forbiddenShortTransitions: Set<PairTransitionKey> = []
        var acceptedEvaluationCache: [PairGroupKey: PairEvaluation] = [:]
        var rejectedEvaluationCache: Set<PairGroupKey> = []
        var aligned: [AlignedSubtitlePhrase] = []

        // A short pair needs confirmation from the final monotone path. If it
        // fails that check, forbid the transition and rerun so it cannot occupy
        // the path and hide a valid longer pair. Three bounded retries keep the
        // worst-case runtime predictable; the final pass still fails closed.
        for attempt in 0...3 {
            let candidate = try alignedPhrases(
                primaryGroups: primaryGroups,
                secondaryGroups: secondaryGroups,
                forbiddenTransitions: forbiddenShortTransitions,
                acceptedEvaluationCache: &acceptedEvaluationCache,
                rejectedEvaluationCache: &rejectedEvaluationCache
            )
            let confirmed = confirmedShortPhrases(in: candidate)
            let confirmedKeys = Set(confirmed.map(PairTransitionKey.init))
            let rejected = candidate.filter {
                $0.isShortUtterance
                    && !confirmedKeys.contains(PairTransitionKey($0))
            }

            if rejected.isEmpty {
                aligned = candidate
                break
            }
            if attempt == 3 {
                aligned = confirmed
                break
            }
            forbiddenShortTransitions.formUnion(rejected.map(PairTransitionKey.init))
        }

        return SubtitlePhraseAlignment(
            primaryFragments: primary,
            secondaryFragments: secondary,
            alignedPhrases: aligned,
            modelVersion: modelVersion
        )
    }

    private func alignedPhrases(
        primaryGroups: [[FragmentGroup?]],
        secondaryGroups: [[FragmentGroup?]],
        forbiddenTransitions: Set<PairTransitionKey>,
        acceptedEvaluationCache: inout [PairGroupKey: PairEvaluation],
        rejectedEvaluationCache: inout Set<PairGroupKey>
    ) throws -> [AlignedSubtitlePhrase] {
        let primaryCount = primary.count
        let secondaryCount = secondary.count
        let columnCount = secondaryCount + 1
        let directionCount = try safeDirectionCount(
            rowCount: primaryCount + 1,
            columnCount: columnCount
        )
        var directions = ContiguousArray<UInt8>(repeating: 0, count: directionCount)
        var scoreRows = Array(
            repeating: Array(repeating: -Double.infinity, count: columnCount),
            count: configuration.maximumGroupSize + 1
        )

        scoreRows[0][0] = 0
        if secondaryCount > 0 {
            for secondaryIndex in 1...secondaryCount {
                scoreRows[0][secondaryIndex] = -Double(secondaryIndex)
                    * configuration.secondarySkipPenalty
                directions[secondaryIndex] = Direction.skipSecondary.rawValue
            }
        }

        if primaryCount > 0 {
            for primaryIndex in 1...primaryCount {
                if primaryIndex.isMultiple(of: 16) {
                    try Task.checkCancellation()
                }
                let currentRowIndex = primaryIndex % scoreRows.count
                let previousRowIndex = (primaryIndex - 1) % scoreRows.count
                scoreRows[currentRowIndex][0] = -Double(primaryIndex)
                    * configuration.primarySkipPenalty
                directions[primaryIndex * columnCount] = Direction.skipPrimary.rawValue

                if secondaryCount == 0 { continue }
                for secondaryIndex in 1...secondaryCount {
                    var bestScore = scoreRows[previousRowIndex][secondaryIndex]
                        - configuration.primarySkipPenalty
                    var bestDirection = Direction.skipPrimary.rawValue

                    let skipSecondaryScore = scoreRows[currentRowIndex][secondaryIndex - 1]
                        - configuration.secondarySkipPenalty
                    if skipSecondaryScore > bestScore + 1e-12 {
                        bestScore = skipSecondaryScore
                        bestDirection = Direction.skipSecondary.rawValue
                    }

                    let maximumPrimaryLength = min(
                        configuration.maximumGroupSize,
                        primaryIndex
                    )
                    let maximumSecondaryLength = min(
                        configuration.maximumGroupSize,
                        secondaryIndex
                    )
                    for primaryLength in 1...maximumPrimaryLength {
                        guard let primaryGroup = primaryGroups[primaryIndex - primaryLength][primaryLength - 1] else {
                            continue
                        }
                        let sourceRow = scoreRows[(primaryIndex - primaryLength) % scoreRows.count]
                        for secondaryLength in 1...maximumSecondaryLength {
                            guard let secondaryGroup = secondaryGroups[secondaryIndex - secondaryLength][secondaryLength - 1] else {
                                continue
                            }
                            let groupKey = PairGroupKey(
                                primaryStartIndex: primaryGroup.startIndex,
                                primaryLength: primaryLength,
                                secondaryStartIndex: secondaryGroup.startIndex,
                                secondaryLength: secondaryLength
                            )
                            guard let evaluation = cachedEvaluation(
                                    primary: primaryGroup,
                                    secondary: secondaryGroup,
                                    key: groupKey,
                                    accepted: &acceptedEvaluationCache,
                                    rejected: &rejectedEvaluationCache
                                  ) else {
                                continue
                            }
                            let transition = PairTransitionKey(
                                primary: primaryGroup.fragments.map(\.id),
                                secondary: secondaryGroup.fragments.map(\.id)
                            )
                            guard !forbiddenTransitions.contains(transition) else {
                                continue
                            }

                            let contribution = pairContribution(
                                evaluation: evaluation,
                                primaryCount: primaryLength,
                                secondaryCount: secondaryLength
                            )
                            let candidateScore = sourceRow[secondaryIndex - secondaryLength]
                                + contribution
                            if candidateScore > bestScore + 1e-12 {
                                bestScore = candidateScore
                                bestDirection = Self.pairDirection(
                                    primaryLength: primaryLength,
                                    secondaryLength: secondaryLength
                                )
                            }
                        }
                    }

                    scoreRows[currentRowIndex][secondaryIndex] = bestScore
                    directions[primaryIndex * columnCount + secondaryIndex] = bestDirection
                }
            }
        }

        var aligned: [AlignedSubtitlePhrase] = []
        var primaryIndex = primaryCount
        var secondaryIndex = secondaryCount
        while primaryIndex > 0 || secondaryIndex > 0 {
            try Task.checkCancellation()
            let rawDirection = directions[primaryIndex * columnCount + secondaryIndex]
            switch rawDirection {
            case Direction.skipPrimary.rawValue:
                guard primaryIndex > 0 else { break }
                primaryIndex -= 1
            case Direction.skipSecondary.rawValue:
                guard secondaryIndex > 0 else { break }
                secondaryIndex -= 1
            default:
                guard let lengths = Self.pairLengths(from: rawDirection),
                      primaryIndex >= lengths.primary,
                      secondaryIndex >= lengths.secondary,
                      let primaryGroup = primaryGroups[primaryIndex - lengths.primary][lengths.primary - 1],
                      let secondaryGroup = secondaryGroups[secondaryIndex - lengths.secondary][lengths.secondary - 1],
                      let evaluation = acceptedEvaluationCache[PairGroupKey(
                        primaryStartIndex: primaryGroup.startIndex,
                        primaryLength: lengths.primary,
                        secondaryStartIndex: secondaryGroup.startIndex,
                        secondaryLength: lengths.secondary
                      )] else {
                    // A corrupt or incomplete path must fail closed: leave the
                    // remaining fragments unmatched instead of inventing a pair.
                    if primaryIndex > 0 {
                        primaryIndex -= 1
                    } else if secondaryIndex > 0 {
                        secondaryIndex -= 1
                    }
                    continue
                }
                aligned.append(evaluation.alignedPhrase)
                primaryIndex -= lengths.primary
                secondaryIndex -= lengths.secondary
            }
        }
        aligned.reverse()
        return aligned
    }

    private func cachedEvaluation(
        primary primaryGroup: FragmentGroup,
        secondary secondaryGroup: FragmentGroup,
        key: PairGroupKey,
        accepted: inout [PairGroupKey: PairEvaluation],
        rejected: inout Set<PairGroupKey>
    ) -> PairEvaluation? {
        // Do not populate the cache with the millions of obviously distant DP
        // cells. Plausible local candidates, including rejections, are reused
        // across bounded reruns and path reconstruction.
        guard abs(primaryGroup.midpoint - secondaryGroup.midpoint)
                <= configuration.maximumCandidateMidpointDistance else {
            return nil
        }
        if let cached = accepted[key] { return cached }
        if rejected.contains(key) { return nil }
        guard let evaluation = evaluate(
            primary: primaryGroup,
            secondary: secondaryGroup
        ) else {
            rejected.insert(key)
            return nil
        }
        accepted[key] = evaluation
        return evaluation
    }

    private func makeGroups(
        from fragments: [SubtitlePhraseFragment]
    ) throws -> [[FragmentGroup?]] {
        var result = Array(
            repeating: Array<FragmentGroup?>(
                repeating: nil,
                count: configuration.maximumGroupSize
            ),
            count: fragments.count
        )
        guard !fragments.isEmpty else { return result }

        for startIndex in fragments.indices {
            for length in 1...configuration.maximumGroupSize {
                let endIndex = startIndex + length
                guard endIndex <= fragments.count else { break }
                let groupFragments = Array(fragments[startIndex..<endIndex])
                guard isValidGroup(groupFragments) else { break }
                guard hasCoherentContinuationBoundaries(
                    startIndex: startIndex,
                    endIndex: endIndex,
                    in: fragments
                ) else {
                    // A longer group may include the lowercase continuation
                    // which makes this boundary coherent, so do not break.
                    continue
                }
                result[startIndex][length - 1] = try makeGroup(
                    groupFragments,
                    startIndex: startIndex
                )
            }
        }
        return result
    }

    private func isValidGroup(_ fragments: [SubtitlePhraseFragment]) -> Bool {
        guard let first = fragments.first, let last = fragments.last else { return false }
        guard last.videoEnd - first.videoStart <= configuration.maximumGroupDuration else {
            return false
        }
        if fragments.count > 1 {
            for index in 1..<fragments.count {
                let gap = fragments[index].videoStart - fragments[index - 1].videoEnd
                if gap > configuration.maximumGroupGap {
                    return false
                }
            }
        }
        return true
    }

    private func hasCoherentContinuationBoundaries(
        startIndex: Int,
        endIndex: Int,
        in fragments: [SubtitlePhraseFragment]
    ) -> Bool {
        if startIndex > 0,
           Self.isLowercaseCrossCueContinuation(
            previous: fragments[startIndex - 1],
            current: fragments[startIndex]
           ) {
            return false
        }
        if endIndex < fragments.count,
           Self.isLowercaseCrossCueContinuation(
            previous: fragments[endIndex - 1],
            current: fragments[endIndex]
           ) {
            return false
        }
        return true
    }

    private static func isLowercaseCrossCueContinuation(
        previous: SubtitlePhraseFragment,
        current: SubtitlePhraseFragment
    ) -> Bool {
        guard previous.id.cueIndex != current.id.cueIndex else {
            return false
        }
        // Ellipsis is an explicit unfinished boundary even when the following
        // cue starts with a capital letter or quote. An explicit speaker change
        // is a stronger context boundary and must remain independently pairable.
        if Self.hasTrailingEllipsis(previous.text) {
            return !current.startsNewSpeaker
        }
        guard !previous.endsSentence,
              !current.startsNewSpeaker,
              let firstLetter = current.text.unicodeScalars.first(where: {
                CharacterSet.letters.contains($0)
              }) else {
            return false
        }
        return CharacterSet.lowercaseLetters.contains(firstLetter)
    }

    private static func hasTrailingEllipsis(_ text: String) -> Bool {
        let trimmed = text
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: "\"'«»“”()[]{}")
                )
            )
        return trimmed.hasSuffix("...") || trimmed.hasSuffix("…")
    }

    private func makeGroup(
        _ fragments: [SubtitlePhraseFragment],
        startIndex: Int
    ) throws -> FragmentGroup {
        let vectors = try fragments.map { fragment -> [Float] in
            let key = SubtitlePhraseAligner.embeddingText(fragment.text)
            guard let vector = embeddingLookup[key] else {
                throw PhraseEmbeddingError.countMismatch(
                    expected: embeddingLookup.count + 1,
                    actual: embeddingLookup.count
                )
            }
            return vector
        }
        let dimension = vectors[0].count
        var combined = Array(repeating: Float(0), count: dimension)
        var totalWeight = 0.0
        for (fragment, vector) in zip(fragments, vectors) {
            let weight = Double(fragment.characterWeight)
            totalWeight += weight
            for index in 0..<dimension {
                combined[index] += Float(Double(vector[index]) * weight)
            }
        }
        if totalWeight > 0 {
            combined = Self.normalizedOrZero(combined)
        }

        return FragmentGroup(
            fragments: fragments,
            startIndex: startIndex,
            endIndex: startIndex + fragments.count,
            text: Self.joinedText(fragments),
            videoStart: fragments.map(\.videoStart).min() ?? 0,
            videoEnd: fragments.map(\.videoEnd).max() ?? 0,
            embedding: combined,
            fragmentEmbeddings: vectors,
            fragmentNegations: fragments.map {
                Self.containsExplicitNegation($0.text)
            },
            characterWeight: fragments.map(\.characterWeight).reduce(0, +),
            endsSentence: fragments.last?.endsSentence ?? false,
            startsNewSpeaker: fragments.first?.startsNewSpeaker ?? false,
            containsNonDialogue: fragments.contains(where: \.isNonDialogue)
        )
    }

    private func evaluate(
        primary primaryGroup: FragmentGroup,
        secondary secondaryGroup: FragmentGroup
    ) -> PairEvaluation? {
        guard !primaryGroup.containsNonDialogue,
              !secondaryGroup.containsNonDialogue else {
            return nil
        }

        let midpointDistance = abs(primaryGroup.midpoint - secondaryGroup.midpoint)
        guard midpointDistance <= configuration.maximumCandidateMidpointDistance else {
            return nil
        }

        let groupSemantic = Self.cosine(
            primaryGroup.embedding,
            secondaryGroup.embedding
        )
        guard let microAlignment = microAlignment(
            primary: primaryGroup,
            secondary: secondaryGroup
        ) else { return nil }
        guard isLocallyUnambiguousSingleton(
            primary: primaryGroup,
            secondary: secondaryGroup,
            semanticScore: groupSemantic
        ) else { return nil }
        guard hasRequiredSingletonNeighborSupport(
            primary: primaryGroup,
            secondary: secondaryGroup,
            semanticScore: groupSemantic
        ) else { return nil }
        guard !hasStrongerOutsideEdgeCompetitor(
            source: primaryGroup,
            target: secondaryGroup,
            targetTrack: secondary
        ), !hasStrongerOutsideEdgeCompetitor(
            source: secondaryGroup,
            target: primaryGroup,
            targetTrack: primary
        ) else {
            return nil
        }
        let semanticScore = Self.clamped(
            groupSemantic * 0.62
                + microAlignment.meanSemanticScore * 0.38
        )
        guard semanticScore >= configuration.minimumSemanticScore else {
            return nil
        }

        let timingScore = Self.timingScore(primaryGroup, secondaryGroup)
        let boundaryScore = Self.boundaryScore(primaryGroup, secondaryGroup)
        let structureScore = Self.structureScore(primaryGroup, secondaryGroup)
        let weightTotal = configuration.semanticWeight
            + configuration.timingWeight
            + configuration.boundaryWeight
            + configuration.structureWeight
        guard weightTotal > 0 else { return nil }
        let confidence = Self.clamped(
            (configuration.semanticWeight * semanticScore
                + configuration.timingWeight * timingScore
                + configuration.boundaryWeight * boundaryScore
                + configuration.structureWeight * structureScore)
                / weightTotal
        )
        guard confidence >= configuration.minimumConfidence else { return nil }

        let phrase = AlignedSubtitlePhrase(
            primaryFragmentIDs: primaryGroup.fragments.map(\.id),
            secondaryFragmentIDs: secondaryGroup.fragments.map(\.id),
            primaryText: primaryGroup.text,
            secondaryText: secondaryGroup.text,
            videoStart: primaryGroup.videoStart,
            videoEnd: primaryGroup.videoEnd,
            secondaryVideoStart: secondaryGroup.videoStart,
            secondaryVideoEnd: secondaryGroup.videoEnd,
            semanticScore: semanticScore,
            timingScore: timingScore,
            boundaryScore: boundaryScore,
            structureScore: structureScore,
            confidence: confidence
        )
        return PairEvaluation(alignedPhrase: phrase)
    }

    /// A candidate must not absorb an edge fragment whose substantially better
    /// translation sits immediately outside the candidate on the same side.
    /// Checking 1↔1 as well prevents DP from replacing a rejected unsafe merge
    /// with the same contextual mismatch as a singleton pair.
    /// This is deliberately fail-closed: the doubtful edge remains unmatched
    /// and can be reconsidered by another monotone transition.
    private func hasStrongerOutsideEdgeCompetitor(
        source sourceGroup: FragmentGroup,
        target targetGroup: FragmentGroup,
        targetTrack: [SubtitlePhraseFragment]
    ) -> Bool {
        if let firstSource = sourceGroup.fragments.first,
           let firstVector = sourceGroup.fragmentEmbeddings.first,
           hasStrongerOutsideCompetitor(
            source: firstSource,
            sourceVector: firstVector,
            internalVectors: targetGroup.fragmentEmbeddings,
            outsideRange: max(targetGroup.startIndex - 2, 0)..<targetGroup.startIndex,
            targetTrack: targetTrack
           ) {
            return true
        }

        if let lastSource = sourceGroup.fragments.last,
           let lastVector = sourceGroup.fragmentEmbeddings.last,
           hasStrongerOutsideCompetitor(
            source: lastSource,
            sourceVector: lastVector,
            internalVectors: targetGroup.fragmentEmbeddings,
            outsideRange: targetGroup.endIndex..<min(
                targetGroup.endIndex + 2,
                targetTrack.count
            ),
            targetTrack: targetTrack
           ) {
            return true
        }
        return false
    }

    private func hasStrongerOutsideCompetitor(
        source: SubtitlePhraseFragment,
        sourceVector: [Float],
        internalVectors: [[Float]],
        outsideRange: Range<Int>,
        targetTrack: [SubtitlePhraseFragment]
    ) -> Bool {
        guard !outsideRange.isEmpty else { return false }
        let internalBest = internalVectors.map {
            Self.cosine(sourceVector, $0)
        }.max() ?? -1

        for index in outsideRange {
            let candidate = targetTrack[index]
            guard !candidate.isNonDialogue,
                  abs(Self.midpoint(of: source) - Self.midpoint(of: candidate))
                    <= configuration.maximumCandidateMidpointDistance else {
                continue
            }
            let key = SubtitlePhraseAligner.embeddingText(candidate.text)
            guard let vector = embeddingLookup[key] else { continue }
            if Self.cosine(sourceVector, vector)
                >= internalBest + configuration.outsideEdgeCompetitionMargin {
                return true
            }
        }
        return false
    }

    private static func midpoint(of fragment: SubtitlePhraseFragment) -> TimeInterval {
        (fragment.videoStart + fragment.videoEnd) / 2
    }

    /// Lower-confidence singleton pairs must be mutual local semantic maxima.
    /// This catches a temporally plausible but shifted line without imposing a
    /// higher global semantic threshold on unique translations.
    private func isLocallyUnambiguousSingleton(
        primary primaryGroup: FragmentGroup,
        secondary secondaryGroup: FragmentGroup,
        semanticScore: Double
    ) -> Bool {
        guard primaryGroup.fragments.count == 1,
              secondaryGroup.fragments.count == 1,
              primaryGroup.fragments.first != nil,
              secondaryGroup.fragments.first != nil else {
            return true
        }
        return isLocallyUnambiguousFragmentPair(
            primaryIndex: primaryGroup.startIndex,
            secondaryIndex: secondaryGroup.startIndex,
            semanticScore: semanticScore
        )
    }

    private func isLocallyUnambiguousFragmentPair(
        primaryIndex: Int,
        secondaryIndex: Int,
        semanticScore: Double
    ) -> Bool {
        guard primary.indices.contains(primaryIndex),
              secondary.indices.contains(secondaryIndex) else {
            return false
        }
        let primaryFragment = primary[primaryIndex]
        let secondaryFragment = secondary[secondaryIndex]
        let primaryKey = SubtitlePhraseAligner.embeddingText(primaryFragment.text)
        let secondaryKey = SubtitlePhraseAligner.embeddingText(secondaryFragment.text)
        guard let primaryVector = embeddingLookup[primaryKey],
              let secondaryVector = embeddingLookup[secondaryKey] else {
            return false
        }
        return !hasMateriallyStrongerLocalCandidate(
            source: primaryFragment,
            sourceVector: primaryVector,
            internalScore: semanticScore,
            excluded: secondaryIndex..<(secondaryIndex + 1),
            targetTrack: secondary
        ) && !hasMateriallyStrongerLocalCandidate(
            source: secondaryFragment,
            sourceVector: secondaryVector,
            internalScore: semanticScore,
            excluded: primaryIndex..<(primaryIndex + 1),
            targetTrack: primary
        )
    }

    private func hasMateriallyStrongerLocalCandidate(
        source: SubtitlePhraseFragment,
        sourceVector: [Float],
        internalScore: Double,
        excluded: Range<Int>,
        targetTrack: [SubtitlePhraseFragment]
    ) -> Bool {
        let neighborRadius = 6
        let start = max(excluded.lowerBound - neighborRadius, 0)
        let end = min(excluded.upperBound + neighborRadius, targetTrack.count)
        for index in start..<end where !excluded.contains(index) {
            let candidate = targetTrack[index]
            guard !candidate.isNonDialogue,
                  abs(Self.midpoint(of: source) - Self.midpoint(of: candidate))
                    <= configuration.maximumCandidateMidpointDistance else {
                continue
            }
            let key = SubtitlePhraseAligner.embeddingText(candidate.text)
            guard let vector = embeddingLookup[key] else { continue }
            if Self.cosine(sourceVector, vector)
                > internalScore + configuration.singletonLocalBestTolerance {
                return true
            }
        }
        return false
    }

    /// A merely plausible singleton can still be a locally shifted reply. It
    /// is eligible only when the immediately preceding and following fragments
    /// form semantically supported, monotone neighbours on both tracks.
    private func hasRequiredSingletonNeighborSupport(
        primary primaryGroup: FragmentGroup,
        secondary secondaryGroup: FragmentGroup,
        semanticScore: Double
    ) -> Bool {
        guard primaryGroup.fragments.count == 1,
              secondaryGroup.fragments.count == 1,
              semanticScore < configuration.minimumShortPhraseSemanticScore else {
            return true
        }
        return hasRequiredFragmentNeighborSupport(
            primaryIndex: primaryGroup.startIndex,
            secondaryIndex: secondaryGroup.startIndex,
            semanticScore: semanticScore
        )
    }

    private func hasRequiredFragmentNeighborSupport(
        primaryIndex: Int,
        secondaryIndex: Int,
        semanticScore: Double
    ) -> Bool {
        guard semanticScore < configuration.minimumShortPhraseSemanticScore else {
            return true
        }
        let primaryPrevious = primaryIndex - 1
        let secondaryPrevious = secondaryIndex - 1
        let primaryNext = primaryIndex + 1
        let secondaryNext = secondaryIndex + 1
        guard primaryPrevious >= 0,
              secondaryPrevious >= 0,
              primaryNext < primary.count,
              secondaryNext < secondary.count else {
            return false
        }
        return isSupportedNeighborPair(
            primary[primaryPrevious], secondary[secondaryPrevious]
        ) && isSupportedNeighborPair(
            primary[primaryNext], secondary[secondaryNext]
        )
    }

    private func isSupportedNeighborPair(
        _ primaryFragment: SubtitlePhraseFragment,
        _ secondaryFragment: SubtitlePhraseFragment
    ) -> Bool {
        guard !primaryFragment.isNonDialogue,
              !secondaryFragment.isNonDialogue,
              abs(Self.midpoint(of: primaryFragment) - Self.midpoint(of: secondaryFragment))
                <= configuration.shortPhraseNeighborTime,
              Self.haveCompatibleExplicitPolarity(
                primaryFragment.text,
                secondaryFragment.text
              ),
              let primaryVector = embeddingLookup[
                SubtitlePhraseAligner.embeddingText(primaryFragment.text)
              ],
              let secondaryVector = embeddingLookup[
                SubtitlePhraseAligner.embeddingText(secondaryFragment.text)
              ] else {
            return false
        }
        return Self.cosine(primaryVector, secondaryVector)
            >= configuration.minimumShortNeighborSemanticScore
    }

    /// Decomposes an opaque group into disjoint monotone semantic units. A
    /// fragment is consumed exactly once; any best path containing a content
    /// gap rejects the whole group instead of displaying an unrelated line.
    private func microAlignment(
        primary primaryGroup: FragmentGroup,
        secondary secondaryGroup: FragmentGroup
    ) -> MicroAlignmentEvaluation? {
        let primaryCount = primaryGroup.fragments.count
        let secondaryCount = secondaryGroup.fragments.count
        var paths = Array(
            repeating: Array<MicroAlignmentPath?>(
                repeating: nil,
                count: secondaryCount + 1
            ),
            count: primaryCount + 1
        )
        paths[0][0] = MicroAlignmentPath(
            score: 0,
            gapCount: 0,
            cellCount: 0,
            mergedFragmentCount: 0,
            semanticTotal: 0
        )
        let cellShapes = [(1, 1), (1, 2), (2, 1)]

        for primaryIndex in 0...primaryCount {
            for secondaryIndex in 0...secondaryCount {
                guard let path = paths[primaryIndex][secondaryIndex] else { continue }

                if primaryIndex < primaryCount {
                    let skipped = path.addingGap(
                        penalty: configuration.microAlignmentGapPenalty
                    )
                    Self.updateMicroPath(
                        skipped,
                        atPrimary: primaryIndex + 1,
                        secondary: secondaryIndex,
                        in: &paths
                    )
                }
                if secondaryIndex < secondaryCount {
                    let skipped = path.addingGap(
                        penalty: configuration.microAlignmentGapPenalty
                    )
                    Self.updateMicroPath(
                        skipped,
                        atPrimary: primaryIndex,
                        secondary: secondaryIndex + 1,
                        in: &paths
                    )
                }

                for (primaryLength, secondaryLength) in cellShapes {
                    let primaryEnd = primaryIndex + primaryLength
                    let secondaryEnd = secondaryIndex + secondaryLength
                    guard primaryEnd <= primaryCount,
                          secondaryEnd <= secondaryCount,
                          let semantic = microCellSemantic(
                            primaryStartIndex: primaryGroup.startIndex + primaryIndex,
                            primaryFragments: Array(
                                primaryGroup.fragments[primaryIndex..<primaryEnd]
                            ),
                            primaryVectors: Array(
                                primaryGroup.fragmentEmbeddings[primaryIndex..<primaryEnd]
                            ),
                            primaryNegations: Array(
                                primaryGroup.fragmentNegations[primaryIndex..<primaryEnd]
                            ),
                            secondaryStartIndex: secondaryGroup.startIndex + secondaryIndex,
                            secondaryFragments: Array(
                                secondaryGroup.fragments[secondaryIndex..<secondaryEnd]
                            ),
                            secondaryVectors: Array(
                                secondaryGroup.fragmentEmbeddings[secondaryIndex..<secondaryEnd]
                            ),
                            secondaryNegations: Array(
                                secondaryGroup.fragmentNegations[secondaryIndex..<secondaryEnd]
                            )
                          ) else {
                        continue
                    }
                    let mergedCount = primaryLength + secondaryLength - 2
                    let matched = path.addingCell(
                        semantic: semantic,
                        mergePenalty: configuration.mergePenalty * Double(mergedCount),
                        mergedFragmentCount: mergedCount
                    )
                    Self.updateMicroPath(
                        matched,
                        atPrimary: primaryEnd,
                        secondary: secondaryEnd,
                        in: &paths
                    )
                }
            }
        }

        guard let result = paths[primaryCount][secondaryCount],
              result.gapCount == 0,
              result.cellCount > 0 else {
            return nil
        }
        return MicroAlignmentEvaluation(
            meanSemanticScore: result.semanticTotal / Double(result.cellCount)
        )
    }

    private func microCellSemantic(
        primaryStartIndex: Int,
        primaryFragments: [SubtitlePhraseFragment],
        primaryVectors: [[Float]],
        primaryNegations: [Bool],
        secondaryStartIndex: Int,
        secondaryFragments: [SubtitlePhraseFragment],
        secondaryVectors: [[Float]],
        secondaryNegations: [Bool]
    ) -> Double? {
        guard !primaryFragments.isEmpty, !secondaryFragments.isEmpty else { return nil }
        let isMergedCell = primaryFragments.count > 1 || secondaryFragments.count > 1
        // A short utterance hidden inside a merge cannot receive the required
        // two-sided path confirmation, so keep that entire cell unpaired.
        guard !isMergedCell || !(primaryFragments + secondaryFragments).contains(
            where: \.isShortUtterance
        ) else { return nil }
        if primaryFragments.count > 1,
           !Self.hasMergeSegmentationEvidence(primaryFragments) {
            return nil
        }
        if secondaryFragments.count > 1,
           !Self.hasMergeSegmentationEvidence(secondaryFragments) {
            return nil
        }
        guard primaryNegations.contains(true) == secondaryNegations.contains(true) else {
            return nil
        }
        let scoreFloor = Self.bidirectionalFragmentScoreFloor(
            primaryVectors,
            secondaryVectors
        )
        guard scoreFloor >= configuration.minimumBidirectionalFragmentScore,
              Self.shortFragmentsHaveStrongCounterparts(
                primaryFragments,
                vectors: primaryVectors,
                candidates: secondaryVectors,
                minimumScore: configuration.minimumShortPhraseSemanticScore
              ),
              Self.shortFragmentsHaveStrongCounterparts(
                secondaryFragments,
                vectors: secondaryVectors,
                candidates: primaryVectors,
                minimumScore: configuration.minimumShortPhraseSemanticScore
              ) else {
            return nil
        }

        let primaryEmbedding = Self.weightedEmbedding(
            fragments: primaryFragments,
            vectors: primaryVectors
        )
        let secondaryEmbedding = Self.weightedEmbedding(
            fragments: secondaryFragments,
            vectors: secondaryVectors
        )
        let semantic = Self.cosine(primaryEmbedding, secondaryEmbedding)
        guard semantic >= configuration.minimumBidirectionalFragmentScore else {
            return nil
        }
        if primaryFragments.count == 1, secondaryFragments.count == 1,
           (!isLocallyUnambiguousFragmentPair(
            primaryIndex: primaryStartIndex,
            secondaryIndex: secondaryStartIndex,
            semanticScore: semantic
           ) || !hasRequiredFragmentNeighborSupport(
            primaryIndex: primaryStartIndex,
            secondaryIndex: secondaryStartIndex,
            semanticScore: semantic
           )) {
            return nil
        }
        return semantic
    }

    private static func updateMicroPath(
        _ candidate: MicroAlignmentPath,
        atPrimary primaryIndex: Int,
        secondary secondaryIndex: Int,
        in paths: inout [[MicroAlignmentPath?]]
    ) {
        guard let current = paths[primaryIndex][secondaryIndex] else {
            paths[primaryIndex][secondaryIndex] = candidate
            return
        }
        if candidate.score > current.score + 1e-12
            || (abs(candidate.score - current.score) <= 1e-12
                && (candidate.gapCount < current.gapCount
                    || (candidate.gapCount == current.gapCount
                        && candidate.mergedFragmentCount < current.mergedFragmentCount))) {
            paths[primaryIndex][secondaryIndex] = candidate
        }
    }

    private static func hasMergeSegmentationEvidence(
        _ fragments: [SubtitlePhraseFragment]
    ) -> Bool {
        guard fragments.count > 1 else { return true }
        for index in 1..<fragments.count {
            let previous = fragments[index - 1]
            let current = fragments[index]
            guard !current.startsNewSpeaker else { return false }
            // Sharing a cue is not evidence that two complete sentences form
            // one translated phrase. Only a syntactically unfinished edge is
            // safe to merge, regardless of whether the edge crosses a cue.
            guard !previous.endsSentence || hasTrailingEllipsis(previous.text) else {
                return false
            }
        }
        return true
    }

    private static func weightedEmbedding(
        fragments: [SubtitlePhraseFragment],
        vectors: [[Float]]
    ) -> [Float] {
        guard let dimension = vectors.first?.count else { return [] }
        var result = Array(repeating: Float(0), count: dimension)
        for (fragment, vector) in zip(fragments, vectors) {
            let weight = Double(fragment.characterWeight)
            for index in 0..<dimension {
                result[index] += Float(Double(vector[index]) * weight)
            }
        }
        return normalizedOrZero(result)
    }

    private static func haveCompatibleExplicitPolarity(
        _ primaryText: String,
        _ secondaryText: String
    ) -> Bool {
        containsExplicitNegation(primaryText) == containsExplicitNegation(secondaryText)
    }

    private static func containsExplicitNegation(_ text: String) -> Bool {
        let tokens = text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: negationTokenSeparators)
            .filter { !$0.isEmpty }
        return tokens.contains { token in
            explicitNegationTokens.contains(token)
                || token.hasPrefix("kein")
                || token.hasSuffix("n't")
        }
    }

    private static let negationTokenSeparators = CharacterSet.letters
        .union(CharacterSet(charactersIn: "'"))
        .inverted

    private static let explicitNegationTokens: Set<String> = [
        "не", "нет", "ни", "никогда", "никто", "ничего", "ничто",
        "нельзя", "негде", "некуда", "никак", "нигде", "нечего",
        "nicht", "nie", "niemals", "niemand", "nichts", "nirgendwo", "weder",
        "not", "no", "never", "nobody", "nothing", "nowhere", "neither",
        "cannot", "can't", "don't", "doesn't", "didn't", "won't",
        "wouldn't", "isn't", "aren't", "wasn't", "weren't", "haven't",
        "hasn't", "hadn't", "couldn't", "shouldn't", "mustn't"
    ]

    private func pairContribution(
        evaluation: PairEvaluation,
        primaryCount: Int,
        secondaryCount: Int
    ) -> Double {
        let coveredUnitCount = Double(min(primaryCount, secondaryCount))
        let mergedFragmentCount = Double(primaryCount + secondaryCount - 2)
        let imbalance = Double(abs(primaryCount - secondaryCount))
        return evaluation.alignedPhrase.confidence * coveredUnitCount
            - configuration.mergePenalty * mergedFragmentCount
            - configuration.imbalancePenalty * imbalance
    }

    private func confirmedShortPhrases(
        in phrases: [AlignedSubtitlePhrase]
    ) -> [AlignedSubtitlePhrase] {
        guard phrases.count >= 3 else {
            return phrases.filter { !$0.isShortUtterance }
        }

        let primaryPositions = Dictionary(
            uniqueKeysWithValues: primary.enumerated().map { ($0.element.id, $0.offset) }
        )
        let secondaryPositions = Dictionary(
            uniqueKeysWithValues: secondary.enumerated().map { ($0.element.id, $0.offset) }
        )

        return phrases.enumerated().compactMap { index, phrase in
            guard phrase.isShortUtterance else { return phrase }
            guard phrase.semanticScore >= configuration.minimumShortPhraseSemanticScore else {
                return nil
            }
            guard index > 0, index + 1 < phrases.count else { return nil }
            let previous = phrases[index - 1]
            let next = phrases[index + 1]
            guard previous.semanticScore >= configuration.minimumShortNeighborSemanticScore,
                  next.semanticScore >= configuration.minimumShortNeighborSemanticScore else {
                return nil
            }
            let precedingTimeGap = max(phrase.videoStart - previous.videoEnd, 0)
            let followingTimeGap = max(next.videoStart - phrase.videoEnd, 0)
            guard precedingTimeGap <= configuration.shortPhraseNeighborTime,
                  followingTimeGap <= configuration.shortPhraseNeighborTime,
                  Self.areSequenceNeighbors(
                    previous.primaryFragmentIDs,
                    phrase.primaryFragmentIDs,
                    next.primaryFragmentIDs,
                    positions: primaryPositions
                  ),
                  Self.areSequenceNeighbors(
                    previous.secondaryFragmentIDs,
                    phrase.secondaryFragmentIDs,
                    next.secondaryFragmentIDs,
                    positions: secondaryPositions
                  ) else {
                return nil
            }
            return phrase
        }
    }

    private static func areSequenceNeighbors(
        _ previous: [SubtitleFragmentID],
        _ current: [SubtitleFragmentID],
        _ next: [SubtitleFragmentID],
        positions: [SubtitleFragmentID: Int]
    ) -> Bool {
        guard let previousLastID = previous.last,
              let currentFirstID = current.first,
              let currentLastID = current.last,
              let nextFirstID = next.first,
              let previousLast = positions[previousLastID],
              let currentFirst = positions[currentFirstID],
              let currentLast = positions[currentLastID],
              let nextFirst = positions[nextFirstID] else {
            return false
        }
        return currentFirst > previousLast
            && currentFirst - previousLast <= 2
            && nextFirst > currentLast
            && nextFirst - currentLast <= 2
    }

    private static func timingScore(
        _ primary: FragmentGroup,
        _ secondary: FragmentGroup
    ) -> Double {
        let overlap = max(
            min(primary.videoEnd, secondary.videoEnd)
                - max(primary.videoStart, secondary.videoStart),
            0
        )
        let union = max(
            max(primary.videoEnd, secondary.videoEnd)
                - min(primary.videoStart, secondary.videoStart),
            0.4
        )
        let overlapRatio = overlap / union
        let primaryDuration = max(primary.duration, 0.4)
        let secondaryDuration = max(secondary.duration, 0.4)
        let durationRatio = min(primaryDuration, secondaryDuration)
            / max(primaryDuration, secondaryDuration)
        let proximityScale = max(1.25, max(primaryDuration, secondaryDuration) * 0.75)
        let midpointProximity = exp(
            -abs(primary.midpoint - secondary.midpoint) / proximityScale
        )
        return clamped(
            overlapRatio * 0.55
                + midpointProximity * 0.30
                + durationRatio * 0.15
        )
    }

    private static func boundaryScore(
        _ primary: FragmentGroup,
        _ secondary: FragmentGroup
    ) -> Double {
        let ending = primary.endsSentence == secondary.endsSentence ? 1.0 : 0.55
        let speaker = primary.startsNewSpeaker == secondary.startsNewSpeaker ? 1.0 : 0.70
        return ending * 0.75 + speaker * 0.25
    }

    private static func structureScore(
        _ primary: FragmentGroup,
        _ secondary: FragmentGroup
    ) -> Double {
        let fragmentRatio = Double(min(primary.fragments.count, secondary.fragments.count))
            / Double(max(primary.fragments.count, secondary.fragments.count))
        let primaryDuration = max(primary.duration, 0.4)
        let secondaryDuration = max(secondary.duration, 0.4)
        let durationRatio = min(primaryDuration, secondaryDuration)
            / max(primaryDuration, secondaryDuration)
        let primaryCharacters = Double(max(primary.characterWeight, 1))
        let secondaryCharacters = Double(max(secondary.characterWeight, 1))
        let characterRatio = min(primaryCharacters, secondaryCharacters)
            / max(primaryCharacters, secondaryCharacters)
        return clamped(
            fragmentRatio * 0.45
                + durationRatio * 0.35
                + sqrt(characterRatio) * 0.20
        )
    }

    private static func fragmentCoverage(
        _ primary: [[Float]],
        _ secondary: [[Float]]
    ) -> Double {
        guard !primary.isEmpty, !secondary.isEmpty else { return 0 }
        let primaryCoverage = primary.map { vector in
            secondary.map { cosine(vector, $0) }.max() ?? -1
        }.reduce(0, +) / Double(primary.count)
        let secondaryCoverage = secondary.map { vector in
            primary.map { cosine(vector, $0) }.max() ?? -1
        }.reduce(0, +) / Double(secondary.count)
        return clamped((primaryCoverage + secondaryCoverage) / 2)
    }

    /// Every fragment in a grouped candidate must have a plausible counterpart
    /// in the other language. The aggregate phrase embedding alone can otherwise
    /// hide one unrelated leading or trailing line inside a strong 2↔2/3↔3 match.
    private static func bidirectionalFragmentScoreFloor(
        _ primary: [[Float]],
        _ secondary: [[Float]]
    ) -> Double {
        guard !primary.isEmpty, !secondary.isEmpty else { return -1 }
        let primaryFloor = primary.map { vector in
            secondary.map { cosine(vector, $0) }.max() ?? -1
        }.min() ?? -1
        let secondaryFloor = secondary.map { vector in
            primary.map { cosine(vector, $0) }.max() ?? -1
        }.min() ?? -1
        return min(primaryFloor, secondaryFloor)
    }

    private static func shortFragmentsHaveStrongCounterparts(
        _ fragments: [SubtitlePhraseFragment],
        vectors: [[Float]],
        candidates: [[Float]],
        minimumScore: Double
    ) -> Bool {
        guard fragments.count == vectors.count, !candidates.isEmpty else { return false }
        for (fragment, vector) in zip(fragments, vectors)
        where fragment.isShortUtterance || isReduplicatedUtterance(fragment.text) {
            let bestScore = candidates.map { cosine(vector, $0) }.max() ?? -1
            if bestScore < minimumScore {
                return false
            }
        }
        return true
    }

    private static func isReduplicatedUtterance(_ text: String) -> Bool {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard tokens.count >= 2, tokens.count <= 6,
              let first = tokens.first else {
            return false
        }
        return tokens.allSatisfy { $0 == first }
    }

    private static func orderedFragmentCoverage(
        _ primary: [[Float]],
        _ secondary: [[Float]]
    ) -> Double {
        guard !primary.isEmpty, !secondary.isEmpty else { return 0 }

        func mappedIndex(_ index: Int, sourceCount: Int, targetCount: Int) -> Int {
            guard sourceCount > 1, targetCount > 1 else { return 0 }
            let position = Double(index) / Double(sourceCount - 1)
            return min(
                max(Int((position * Double(targetCount - 1)).rounded()), 0),
                targetCount - 1
            )
        }

        let primaryScore = primary.enumerated().reduce(0.0) { partial, item in
            let target = mappedIndex(
                item.offset,
                sourceCount: primary.count,
                targetCount: secondary.count
            )
            return partial + cosine(item.element, secondary[target])
        } / Double(primary.count)
        let secondaryScore = secondary.enumerated().reduce(0.0) { partial, item in
            let target = mappedIndex(
                item.offset,
                sourceCount: secondary.count,
                targetCount: primary.count
            )
            return partial + cosine(item.element, primary[target])
        } / Double(secondary.count)
        return clamped((primaryScore + secondaryScore) / 2)
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var result = 0.0
        for index in lhs.indices {
            result += Double(lhs[index]) * Double(rhs[index])
        }
        return min(max(result, -1), 1)
    }

    private static func normalizedOrZero(_ vector: [Float]) -> [Float] {
        let length = sqrt(vector.reduce(0.0) { partial, value in
            partial + Double(value * value)
        })
        guard length > Double.leastNonzeroMagnitude else { return vector }
        return vector.map { Float(Double($0) / length) }
    }

    private static func joinedText(_ fragments: [SubtitlePhraseFragment]) -> String {
        guard var previous = fragments.first else { return "" }
        var result = previous.text
        for fragment in fragments.dropFirst() {
            result += fragment.id.cueIndex == previous.id.cueIndex ? " " : "\n"
            result += fragment.text
            previous = fragment
        }
        return result
    }

    private static func pairDirection(
        primaryLength: Int,
        secondaryLength: Int
    ) -> UInt8 {
        UInt8(3 + (primaryLength - 1) * 3 + (secondaryLength - 1))
    }

    private static func pairLengths(
        from direction: UInt8
    ) -> (primary: Int, secondary: Int)? {
        guard direction >= 3, direction <= 11 else { return nil }
        let value = Int(direction - 3)
        return (value / 3 + 1, value % 3 + 1)
    }

    private func safeDirectionCount(rowCount: Int, columnCount: Int) throws -> Int {
        let (result, overflow) = rowCount.multipliedReportingOverflow(by: columnCount)
        if overflow {
            throw PhraseEmbeddingError.countMismatch(expected: rowCount, actual: columnCount)
        }
        return result
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}

private struct FragmentGroup: Sendable {
    let fragments: [SubtitlePhraseFragment]
    let startIndex: Int
    let endIndex: Int
    let text: String
    let videoStart: TimeInterval
    let videoEnd: TimeInterval
    let embedding: [Float]
    let fragmentEmbeddings: [[Float]]
    let fragmentNegations: [Bool]
    let characterWeight: Int
    let endsSentence: Bool
    let startsNewSpeaker: Bool
    let containsNonDialogue: Bool

    var duration: TimeInterval { max(videoEnd - videoStart, 0) }
    var midpoint: TimeInterval { (videoStart + videoEnd) / 2 }
}

private struct PairEvaluation: Sendable {
    let alignedPhrase: AlignedSubtitlePhrase
}

private struct MicroAlignmentEvaluation: Sendable {
    let meanSemanticScore: Double
}

private struct MicroAlignmentPath: Sendable {
    let score: Double
    let gapCount: Int
    let cellCount: Int
    let mergedFragmentCount: Int
    let semanticTotal: Double

    func addingGap(penalty: Double) -> MicroAlignmentPath {
        MicroAlignmentPath(
            score: score - penalty,
            gapCount: gapCount + 1,
            cellCount: cellCount,
            mergedFragmentCount: mergedFragmentCount,
            semanticTotal: semanticTotal
        )
    }

    func addingCell(
        semantic: Double,
        mergePenalty: Double,
        mergedFragmentCount addedMergedCount: Int
    ) -> MicroAlignmentPath {
        MicroAlignmentPath(
            score: score + semantic - mergePenalty,
            gapCount: gapCount,
            cellCount: cellCount + 1,
            mergedFragmentCount: mergedFragmentCount + addedMergedCount,
            semanticTotal: semanticTotal + semantic
        )
    }
}

private struct PairTransitionKey: Hashable, Sendable {
    let primary: [SubtitleFragmentID]
    let secondary: [SubtitleFragmentID]

    init(primary: [SubtitleFragmentID], secondary: [SubtitleFragmentID]) {
        self.primary = primary
        self.secondary = secondary
    }

    init(_ phrase: AlignedSubtitlePhrase) {
        primary = phrase.primaryFragmentIDs
        secondary = phrase.secondaryFragmentIDs
    }
}

private struct PairGroupKey: Hashable, Sendable {
    let primaryStartIndex: Int
    let primaryLength: Int
    let secondaryStartIndex: Int
    let secondaryLength: Int
}

private enum Direction: UInt8 {
    case skipPrimary = 1
    case skipSecondary = 2
}
