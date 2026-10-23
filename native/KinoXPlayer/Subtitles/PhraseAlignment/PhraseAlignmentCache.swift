import CryptoKit
import Foundation

actor PhraseAlignmentCache {
    private struct Envelope: Codable {
        let payload: Payload
        let checksum: String
    }

    private struct Payload: Codable {
        let formatVersion: Int
        let modelVersion: String
        let primaryFragments: [SubtitlePhraseFragment]
        let secondaryFragments: [SubtitlePhraseFragment]
        let alignedPhrases: [AlignedSubtitlePhrase]
    }

    private enum ValidationError: Error {
        case invalidPayload
    }

    private static let formatVersion = 2
    private static let maximumByteCount: Int64 = 128 * 1_024 * 1_024
    private static let maximumFragmentCount = 1_000_000
    private static let maximumFragmentTextByteCount = 1_048_576
    private static let minimumSemanticScore = 0.35
    private static let minimumConfidence = 0.75

    private let rootURL: URL
    private let derivedCacheBudget: PhraseAlignmentDerivedCacheBudget
    private let fileManager: FileManager

    init(
        rootURL: URL? = nil,
        derivedCacheBudget: PhraseAlignmentDerivedCacheBudget = .shared
    ) {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.derivedCacheBudget = derivedCacheBudget
    }

    func alignment(forKey key: String) async -> SubtitlePhraseAlignment? {
        guard Self.isValidKey(key) else { return nil }
        await derivedCacheBudget.pruneOnFirstAccess(rootURL: rootURL)
        let url = rootURL.appendingPathComponent("\(key).json", isDirectory: false)
        guard isSafeRegularFile(url),
              let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(fileSize) <= Self.maximumByteCount else {
            removeInvalidRegularFile(at: url)
            return nil
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            let payload = envelope.payload
            guard payload.formatVersion == Self.formatVersion,
                  Self.isValidChecksum(envelope.checksum, for: payload),
                  Self.isStructurallyValid(payload) else {
                throw ValidationError.invalidPayload
            }
            try? fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path
            )
            return SubtitlePhraseAlignment(
                primaryFragments: payload.primaryFragments,
                secondaryFragments: payload.secondaryFragments,
                alignedPhrases: payload.alignedPhrases,
                modelVersion: payload.modelVersion
            )
        } catch {
            removeInvalidRegularFile(at: url)
            return nil
        }
    }

    func store(_ alignment: SubtitlePhraseAlignment, forKey key: String) async throws {
        guard Self.isValidKey(key) else { return }
        try prepareRoot()

        let payload = Payload(
            formatVersion: Self.formatVersion,
            modelVersion: alignment.modelVersion,
            primaryFragments: alignment.primaryFragments,
            secondaryFragments: alignment.secondaryFragments,
            alignedPhrases: alignment.alignedPhrases
        )
        guard Self.isStructurallyValid(payload) else {
            throw ValidationError.invalidPayload
        }
        let envelope = Envelope(
            payload: payload,
            checksum: try Self.checksum(for: payload)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let destination = rootURL.appendingPathComponent("\(key).json", isDirectory: false)
        if fileManager.fileExists(atPath: destination.path), !isSafeRegularFile(destination) {
            throw CocoaError(.fileWriteFileExists)
        }
        try data.write(to: destination, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        await derivedCacheBudget.prune(rootURL: rootURL)
    }

    static func makeKey(
        primaryCues: [SubtitleCue],
        primaryTransform: SubtitleTimingTransform,
        primaryOffset: TimeInterval,
        primaryLanguageCode: String?,
        secondaryCues: [SubtitleCue],
        secondaryTransform: SubtitleTimingTransform,
        secondaryOffset: TimeInterval,
        secondaryLanguageCode: String?,
        modelVersion: String
    ) -> String {
        var hasher = SHA256()
        update(&hasher, string: SubtitlePhraseAlignment.algorithmVersion)
        update(&hasher, string: "subtitle-fragmenter-v2")
        update(&hasher, string: modelVersion)
        update(
            &hasher,
            cues: primaryCues,
            transform: primaryTransform,
            offset: primaryOffset,
            languageCode: primaryLanguageCode
        )
        update(
            &hasher,
            cues: secondaryCues,
            transform: secondaryTransform,
            offset: secondaryOffset,
            languageCode: secondaryLanguageCode
        )
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(
        _ hasher: inout SHA256,
        cues: [SubtitleCue],
        transform: SubtitleTimingTransform,
        offset: TimeInterval,
        languageCode: String?
    ) {
        update(&hasher, value: UInt64(cues.count))
        update(&hasher, value: transform.offset.bitPattern)
        update(&hasher, value: transform.rate.bitPattern)
        update(&hasher, value: offset.bitPattern)
        update(&hasher, string: languageCode?.lowercased() ?? "")
        for cue in cues {
            update(&hasher, value: cue.start.bitPattern)
            update(&hasher, value: cue.end.bitPattern)
            update(&hasher, string: cue.text)
        }
    }

    private static func update(_ hasher: inout SHA256, string: String) {
        let data = Data(string.utf8)
        update(&hasher, value: UInt64(data.count))
        hasher.update(data: data)
    }

    private static func update(_ hasher: inout SHA256, value: UInt64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            hasher.update(bufferPointer: bytes)
        }
    }

    private static func checksum(for payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isValidChecksum(
        _ checksum: String,
        for payload: Payload
    ) -> Bool {
        guard checksum.count == 64,
              checksum.allSatisfy(\.isHexDigit),
              let expected = try? Self.checksum(for: payload) else {
            return false
        }
        return checksum.lowercased() == expected
    }

    private static func isStructurallyValid(_ payload: Payload) -> Bool {
        guard payload.formatVersion == Self.formatVersion,
              !payload.modelVersion.isEmpty,
              payload.modelVersion.utf8.count <= 512,
              fragmentsAreValid(payload.primaryFragments),
              fragmentsAreValid(payload.secondaryFragments) else {
            return false
        }

        let primaryPositions = Dictionary(
            uniqueKeysWithValues: payload.primaryFragments.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        let secondaryPositions = Dictionary(
            uniqueKeysWithValues: payload.secondaryFragments.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        var pairedPrimaryIDs: Set<SubtitleFragmentID> = []
        var pairedSecondaryIDs: Set<SubtitleFragmentID> = []
        var previousPrimaryEndPosition = -1
        var previousSecondaryEndPosition = -1

        for phrase in payload.alignedPhrases {
            guard (1...3).contains(phrase.primaryFragmentIDs.count),
                  (1...3).contains(phrase.secondaryFragmentIDs.count),
                  scoresAreValid(for: phrase),
                  phrase.semanticScore >= Self.minimumSemanticScore,
                  phrase.confidence >= Self.minimumConfidence,
                  phrase.videoStart.isFinite,
                  phrase.videoEnd.isFinite,
                  phrase.videoEnd > phrase.videoStart,
                  phrase.secondaryVideoStart.isFinite,
                  phrase.secondaryVideoEnd.isFinite,
                  phrase.secondaryVideoEnd > phrase.secondaryVideoStart else {
                return false
            }

            guard let primaryGroup = resolvedGroup(
                ids: phrase.primaryFragmentIDs,
                fragments: payload.primaryFragments,
                positions: primaryPositions
            ), let secondaryGroup = resolvedGroup(
                ids: phrase.secondaryFragmentIDs,
                fragments: payload.secondaryFragments,
                positions: secondaryPositions
            ), primaryGroup.firstPosition > previousPrimaryEndPosition,
               secondaryGroup.firstPosition > previousSecondaryEndPosition,
               !primaryGroup.fragments.contains(where: \.isNonDialogue),
               !secondaryGroup.fragments.contains(where: \.isNonDialogue),
               phrase.primaryText == joinedText(primaryGroup.fragments),
               phrase.secondaryText == joinedText(secondaryGroup.fragments),
               nearlyEqual(
                phrase.videoStart,
                primaryGroup.fragments.map(\.videoStart).min() ?? .nan
               ),
               nearlyEqual(
                phrase.videoEnd,
                primaryGroup.fragments.map(\.videoEnd).max() ?? .nan
               ),
               nearlyEqual(
                phrase.secondaryVideoStart,
                secondaryGroup.fragments.map(\.videoStart).min() ?? .nan
               ),
               nearlyEqual(
                phrase.secondaryVideoEnd,
                secondaryGroup.fragments.map(\.videoEnd).max() ?? .nan
               ) else {
                return false
            }

            for id in phrase.primaryFragmentIDs {
                guard pairedPrimaryIDs.insert(id).inserted else { return false }
            }
            for id in phrase.secondaryFragmentIDs {
                guard pairedSecondaryIDs.insert(id).inserted else { return false }
            }
            previousPrimaryEndPosition = primaryGroup.lastPosition
            previousSecondaryEndPosition = secondaryGroup.lastPosition
        }
        return true
    }

    private static func fragmentsAreValid(
        _ fragments: [SubtitlePhraseFragment]
    ) -> Bool {
        guard fragments.count <= Self.maximumFragmentCount else { return false }

        var ids: Set<SubtitleFragmentID> = []
        var fragmentIndicesByCue: [Int: [Int]] = [:]
        var previousStart = -Double.infinity
        for fragment in fragments {
            guard fragment.id.cueIndex >= 0,
                  (0..<SubtitlePhraseFragmenter.maximumFragmentsPerCue)
                    .contains(fragment.id.fragmentIndex),
                  ids.insert(fragment.id).inserted,
                  !fragment.text.isEmpty,
                  fragment.text.utf8.count <= Self.maximumFragmentTextByteCount,
                  fragment.videoStart.isFinite,
                  fragment.videoEnd.isFinite,
                  fragment.videoEnd > fragment.videoStart,
                  fragment.videoStart >= previousStart,
                  fragment.characterWeight == characterWeight(for: fragment.text) else {
                return false
            }
            fragmentIndicesByCue[fragment.id.cueIndex, default: []]
                .append(fragment.id.fragmentIndex)
            previousStart = fragment.videoStart
        }

        return fragmentIndicesByCue.values.allSatisfy { indices in
            let ordered = indices.sorted()
            return ordered == Array(0..<ordered.count)
        }
    }

    private static func scoresAreValid(for phrase: AlignedSubtitlePhrase) -> Bool {
        [
            phrase.semanticScore,
            phrase.timingScore,
            phrase.boundaryScore,
            phrase.structureScore,
            phrase.confidence,
        ].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    private static func resolvedGroup(
        ids: [SubtitleFragmentID],
        fragments: [SubtitlePhraseFragment],
        positions: [SubtitleFragmentID: Int]
    ) -> (
        fragments: [SubtitlePhraseFragment],
        firstPosition: Int,
        lastPosition: Int
    )? {
        let resolvedPositions = ids.compactMap { positions[$0] }
        guard resolvedPositions.count == ids.count,
              let first = resolvedPositions.first,
              let last = resolvedPositions.last,
              resolvedPositions == Array(first...last) else {
            return nil
        }
        return (ids.map { fragments[positions[$0]!] }, first, last)
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

    private static func characterWeight(for text: String) -> Int {
        max(text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                count += 1
            }
        }, 1)
    }

    private static func nearlyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        let scale = max(abs(lhs), abs(rhs), 1)
        return abs(lhs - rhs) <= scale * 1e-12
    }

    private func prepareRoot() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } else {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
        var mutableURL = rootURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL
            == rootURL.standardizedFileURL else {
            return false
        }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func removeInvalidRegularFile(at url: URL) {
        guard isSafeRegularFile(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func isValidKey(_ key: String) -> Bool {
        key.count == 64 && key.allSatisfy { $0.isHexDigit }
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("KinoXPlayer", isDirectory: true)
            .appendingPathComponent("Phrase Alignment Cache", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}
