import CryptoKit
import Foundation
import XCTest
@testable import KinoXPlayer

final class PhraseAlignmentCacheTests: XCTestCase {
    func testAlignmentRoundTripsAndCorruptionIsIgnored() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cache = PhraseAlignmentCache(rootURL: rootURL)
        let alignment = makeAlignment()
        let key = String(repeating: "a", count: 64)

        try await cache.store(alignment, forKey: key)
        let restored = await cache.alignment(forKey: key)
        XCTAssertEqual(restored, alignment)

        let fileURL = rootURL.appendingPathComponent("\(key).json")
        try Data("not-json".utf8).write(to: fileURL, options: .atomic)
        let corrupted = await cache.alignment(forKey: key)
        XCTAssertNil(corrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testValidJSONTamperingIsRejectedAndRemoved() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cache = PhraseAlignmentCache(rootURL: rootURL)
        let key = String(repeating: "b", count: 64)
        try await cache.store(makeAlignment(), forKey: key)

        let fileURL = rootURL.appendingPathComponent("\(key).json")
        let original = try String(contentsOf: fileURL, encoding: .utf8)
        let tampered = original.replacingOccurrences(of: "Hallo.", with: "Fremd.")
        XCTAssertNotEqual(tampered, original)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(tampered.utf8)))
        try Data(tampered.utf8).write(to: fileURL, options: .atomic)

        let restored = await cache.alignment(forKey: key)
        XCTAssertNil(restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAlignmentCachePrunesToEightyMovies() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cache = PhraseAlignmentCache(rootURL: rootURL)
        let alignment = makeAlignment()

        for value in 0..<84 {
            let key = SHA256.hash(data: Data("movie-\(value)".utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            try await cache.store(alignment, forKey: key)
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertLessThanOrEqual(entries.count, 80)
    }

    func testDerivedBudgetCountsDirectCustomLayoutAlongsideNestedLayout() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let nestedRoot = rootURL.appendingPathComponent("Embeddings", isDirectory: true)
        let directPrefix = rootURL.appendingPathComponent("ab", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: directPrefix,
            withIntermediateDirectories: false
        )
        let directFile = directPrefix.appendingPathComponent(
            "\(String(repeating: "c", count: 64)).f16"
        )
        try Data(repeating: 0xA5, count: 4_096).write(to: directFile)

        let budget = PhraseAlignmentDerivedCacheBudget(
            maximumAlignmentCount: 80,
            maximumAllocatedByteCount: 1
        )
        await budget.prune(rootURL: rootURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directFile.path))
    }

    func testCacheHitPrunesRootOnlyOncePerBudgetProcess() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let key = String(repeating: "a", count: 64)
        let seededCache = PhraseAlignmentCache(
            rootURL: rootURL,
            derivedCacheBudget: PhraseAlignmentDerivedCacheBudget(
                maximumAlignmentCount: 100,
                maximumAllocatedByteCount: Int64.max
            )
        )
        try await seededCache.store(makeAlignment(), forKey: key)

        let oldDummyURL = rootURL.appendingPathComponent(
            "\(String(repeating: "b", count: 64)).json"
        )
        try Data("{}".utf8).write(to: oldDummyURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: oldDummyURL.path
        )
        let alignmentURL = rootURL.appendingPathComponent("\(key).json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: alignmentURL.path
        )

        let accessBudget = PhraseAlignmentDerivedCacheBudget(
            maximumAlignmentCount: 1,
            maximumAllocatedByteCount: Int64.max
        )
        let reopened = PhraseAlignmentCache(
            rootURL: rootURL,
            derivedCacheBudget: accessBudget
        )
        let firstHit = await reopened.alignment(forKey: key)
        XCTAssertNotNil(firstHit)
        XCTAssertEqual(jsonEntryCount(in: rootURL), 1)

        let laterDummyURL = rootURL.appendingPathComponent(
            "\(String(repeating: "d", count: 64)).json"
        )
        try Data("{}".utf8).write(to: laterDummyURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 3_600)],
            ofItemAtPath: alignmentURL.path
        )

        let secondHit = await reopened.alignment(forKey: key)
        XCTAssertNotNil(secondHit)
        XCTAssertEqual(jsonEntryCount(in: rootURL), 2)
    }

    func testBudgetContinuesAfterAnEntryCannotBeRemoved() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let keys = ["a", "b", "c"].map { String(repeating: $0, count: 64) }
        let urls = keys.map { rootURL.appendingPathComponent("\($0).json") }
        for (index, url) in urls.enumerated() {
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index + 1))],
                ofItemAtPath: url.path
            )
        }
        let immutableURL = urls[0]
        try FileManager.default.setAttributes(
            [.immutable: true],
            ofItemAtPath: immutableURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: immutableURL.path
            )
        }

        let budget = PhraseAlignmentDerivedCacheBudget(
            maximumAlignmentCount: 2,
            maximumAllocatedByteCount: Int64.max
        )
        await budget.prune(rootURL: rootURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: immutableURL.path))
        XCTAssertEqual(jsonEntryCount(in: rootURL), 2)
    }

    func testCacheKeyIncludesTextTimingOffsetTransformLanguageAndModel() {
        let cue = SubtitleCue(start: 1, end: 2, text: "Hello")
        let base = PhraseAlignmentCache.makeKey(
            primaryCues: [cue],
            primaryTransform: .identity,
            primaryOffset: 0,
            primaryLanguageCode: "en",
            secondaryCues: [cue],
            secondaryTransform: .identity,
            secondaryOffset: 0,
            secondaryLanguageCode: "de",
            modelVersion: "model-a"
        )
        let changedText = PhraseAlignmentCache.makeKey(
            primaryCues: [SubtitleCue(start: 1, end: 2, text: "Different")],
            primaryTransform: .identity,
            primaryOffset: 0,
            primaryLanguageCode: "en",
            secondaryCues: [cue],
            secondaryTransform: .identity,
            secondaryOffset: 0,
            secondaryLanguageCode: "de",
            modelVersion: "model-a"
        )
        let changedTiming = PhraseAlignmentCache.makeKey(
            primaryCues: [cue],
            primaryTransform: SubtitleTimingTransform(offset: 0.4, rate: 1.001),
            primaryOffset: 0.2,
            primaryLanguageCode: "en",
            secondaryCues: [cue],
            secondaryTransform: .identity,
            secondaryOffset: 0,
            secondaryLanguageCode: "de",
            modelVersion: "model-a"
        )
        let changedModel = PhraseAlignmentCache.makeKey(
            primaryCues: [cue],
            primaryTransform: .identity,
            primaryOffset: 0,
            primaryLanguageCode: "en",
            secondaryCues: [cue],
            secondaryTransform: .identity,
            secondaryOffset: 0,
            secondaryLanguageCode: "de",
            modelVersion: "model-b"
        )

        XCTAssertEqual(Set([base, changedText, changedTiming, changedModel]).count, 4)
    }

    func testFloat16EmbeddingCacheAvoidsReencodingUniqueText() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let base = CountingPhraseEmbeddingProvider()
        let first = CachedPhraseEmbeddingProvider(base: base, rootURL: rootURL)
        let firstValues = try await first.embeddings(for: ["Привет", "Hallo", "Привет"])
        let firstEncodedCount = await base.encodedTextCount
        XCTAssertEqual(firstEncodedCount, 2)

        let reopened = CachedPhraseEmbeddingProvider(base: base, rootURL: rootURL)
        let secondValues = try await reopened.embeddings(for: ["Привет", "Hallo"])
        let secondEncodedCount = await base.encodedTextCount
        XCTAssertEqual(secondEncodedCount, 2)
        XCTAssertEqual(firstValues[0][0], secondValues[0][0], accuracy: 0.001)
        XCTAssertEqual(firstValues[1][1], secondValues[1][1], accuracy: 0.001)
        XCTAssertTrue(secondValues.flatMap { $0 }.contains(where: { $0 < 0 }))
    }

    private func makeAlignment() -> SubtitlePhraseAlignment {
        let primary = SubtitlePhraseFragment(
            id: SubtitleFragmentID(cueIndex: 0, fragmentIndex: 0),
            text: "Hello.",
            videoStart: 1,
            videoEnd: 2,
            endsSentence: true,
            startsNewSpeaker: false,
            isNonDialogue: false,
            characterWeight: 5
        )
        let secondary = SubtitlePhraseFragment(
            id: SubtitleFragmentID(cueIndex: 0, fragmentIndex: 0),
            text: "Hallo.",
            videoStart: 1.1,
            videoEnd: 2.1,
            endsSentence: true,
            startsNewSpeaker: false,
            isNonDialogue: false,
            characterWeight: 5
        )
        let pair = AlignedSubtitlePhrase(
            primaryFragmentIDs: [primary.id],
            secondaryFragmentIDs: [secondary.id],
            primaryText: primary.text,
            secondaryText: secondary.text,
            videoStart: primary.videoStart,
            videoEnd: primary.videoEnd,
            secondaryVideoStart: secondary.videoStart,
            secondaryVideoEnd: secondary.videoEnd,
            semanticScore: 0.95,
            timingScore: 0.9,
            boundaryScore: 1,
            structureScore: 1,
            confidence: 0.94
        )
        return SubtitlePhraseAlignment(
            primaryFragments: [primary],
            secondaryFragments: [secondary],
            alignedPhrases: [pair],
            modelVersion: "test-model"
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinoXPlayer-PhraseCacheTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonEntryCount(in rootURL: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter { $0.pathExtension.lowercased() == "json" }.count) ?? 0
    }
}

private actor CountingPhraseEmbeddingProvider: PhraseEmbeddingProviding {
    nonisolated let modelVersion = "counting-test-model"
    private(set) var encodedTextCount = 0

    func embeddings(for texts: [String]) async throws -> [[Float]] {
        encodedTextCount += texts.count
        return texts.enumerated().map { index, _ in
            index.isMultiple(of: 2) ? [-0.8, 0.6] : [0.6, -0.8]
        }
    }
}
