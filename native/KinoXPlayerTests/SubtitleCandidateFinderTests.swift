import Foundation
import XCTest
@testable import KinoXPlayer

final class SubtitleCandidateFinderTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testFinderRanksMatchingNameAndRejectsInvalidSubtitle() throws {
        let folder = try makeTemporaryDirectory()
        let matchingURL = folder.appendingPathComponent("Example.Movie.2004.Rus-Full.srt")
        let unrelatedURL = folder.appendingPathComponent("Unrelated.Show.2019.vtt")
        let invalidURL = folder.appendingPathComponent("Example.Movie.2004.broken.srt")
        let ignoredURL = folder.appendingPathComponent("Example.Movie.2004.txt")

        try subtitleText(lastStart: 3_480).write(to: matchingURL, atomically: true, encoding: .utf8)
        try webVTTText(lastStart: 3_480).write(to: unrelatedURL, atomically: true, encoding: .utf8)
        try "not subtitles".write(to: invalidURL, atomically: true, encoding: .utf8)
        try "ignored".write(to: ignoredURL, atomically: true, encoding: .utf8)

        let result = try LocalSubtitleCandidateFinder().findCandidates(
            in: folder,
            for: SubtitleSearchVideo(
                url: folder.appendingPathComponent("Example Movie (2004).mp4"),
                duration: 3_600
            )
        )

        XCTAssertEqual(result.candidates.map(\.url.lastPathComponent), [
            matchingURL.lastPathComponent,
            unrelatedURL.lastPathComponent
        ])
        XCTAssertGreaterThan(
            try XCTUnwrap(result.candidates.first?.score.fileNameScore),
            try XCTUnwrap(result.candidates.last?.score.fileNameScore)
        )
        XCTAssertEqual(result.rejectedCandidates.count, 1)
        XCTAssertEqual(result.rejectedCandidates.first?.url, invalidURL)
        XCTAssertEqual(result.rejectedCandidates.first?.reason, .noCues)
        XCTAssertFalse(result.wasTruncated)
    }

    func testFinderOnlySearchesNestedFoldersWhenRequested() throws {
        let folder = try makeTemporaryDirectory()
        let nestedFolder = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedFolder,
            withIntermediateDirectories: false
        )
        let nestedSubtitle = nestedFolder.appendingPathComponent("Film.2020.SDH.SRT")
        try subtitleText(lastStart: 1_700).write(
            to: nestedSubtitle,
            atomically: true,
            encoding: .utf8
        )
        let video = SubtitleSearchVideo(
            url: folder.appendingPathComponent("Film.2020.mp4"),
            duration: 1_800
        )

        let shallow = try LocalSubtitleCandidateFinder().findCandidates(
            in: folder,
            for: video
        )
        let recursive = try LocalSubtitleCandidateFinder().findCandidates(
            in: folder,
            for: video,
            options: SubtitleSearchOptions(recursive: true)
        )

        XCTAssertTrue(shallow.candidates.isEmpty)
        XCTAssertEqual(recursive.candidates.map(\.url), [nestedSubtitle])
        XCTAssertEqual(recursive.candidates.first?.format, .srt)
    }

    func testDurationScorePenalizesTimelineThatEndsFarBeforeVideo() {
        let scorer = SubtitleCandidateScorer()
        let video = SubtitleSearchVideo(
            url: URL(fileURLWithPath: "/Movies/Film.2022.mp4"),
            duration: 3_600
        )
        let subtitleURL = URL(fileURLWithPath: "/Subs/Film.2022.srt")
        let matchingTimeline = generatedCues(count: 120, lastStart: 3_470)
        let shortTimeline = generatedCues(count: 120, lastStart: 1_100)

        let matching = scorer.score(
            video: video,
            subtitleURL: subtitleURL,
            cues: matchingTimeline
        )
        let short = scorer.score(
            video: video,
            subtitleURL: subtitleURL,
            cues: shortTimeline
        )

        XCTAssertGreaterThan(matching.durationScore ?? 0, 0.95)
        XCTAssertLessThan(short.durationScore ?? 1, 0.1)
        XCTAssertGreaterThan(matching.totalScore, short.totalScore)
    }

    func testConflictingReleaseYearsStronglyReduceNameScore() {
        let scorer = SubtitleCandidateScorer()
        let video = SubtitleSearchVideo(
            url: URL(fileURLWithPath: "/Movies/Example.Film.2004.mp4"),
            duration: 3_600
        )
        let cues = generatedCues(count: 120, lastStart: 3_470)

        let matchingYear = scorer.score(
            video: video,
            subtitleURL: URL(fileURLWithPath: "/Subs/Example.Film.2004.srt"),
            cues: cues
        )
        let conflictingYear = scorer.score(
            video: video,
            subtitleURL: URL(fileURLWithPath: "/Subs/Example.Film.2014.srt"),
            cues: cues
        )

        XCTAssertGreaterThan(matchingYear.fileNameScore, 0.95)
        XCTAssertLessThan(conflictingYear.fileNameScore, 0.2)
    }

    func testTimingTransformRepresentsOffsetAndFrameRateDrift() {
        let transform = SubtitleTimingTransform(offset: 2.8193, rate: 0.9989774)
        let videoTime: TimeInterval = 3_600
        let subtitleTime = transform.subtitleTime(forVideoTime: videoTime)

        XCTAssertEqual(subtitleTime, 3_599.13794, accuracy: 0.000_01)
        XCTAssertEqual(
            transform.videoTime(forSubtitleTime: subtitleTime),
            videoTime,
            accuracy: 0.000_01
        )
        XCTAssertEqual(transform.driftPerHour, -3.68136, accuracy: 0.000_01)
    }

    func testTrackUsesAutomaticTimingTransformBeforeManualDelay() {
        var track = SubtitleTrack(slot: .primary)
        track.cues = [SubtitleCue(start: 10, end: 11, text: "Aligned")]
        track.timingTransform = SubtitleTimingTransform(offset: 2, rate: 1)

        XCTAssertEqual(track.activeText(at: 8.5), "Aligned")
        XCTAssertEqual(track.activeText(at: 7.5), "")

        track.offset = 1
        XCTAssertEqual(track.activeText(at: 9.5), "Aligned")
        XCTAssertEqual(track.activeText(at: 8.5), "")
    }

    func testCompatibilityMatcherRecoversOffsetAndGradualDrift() throws {
        let folder = try makeTemporaryDirectory()
        let video = SubtitleSearchVideo(
            url: folder.appendingPathComponent("Pattern.Movie.2024.mp4"),
            duration: 1_200,
            frameRate: 24
        )
        let subtitleURL = folder.appendingPathComponent("Pattern.Movie.2024.srt")
        let cues = synchronizationCues()
        let expectedVideoShift = -3.0
        let expectedVideoPerSubtitleRate = 1.002
        let samples = stride(from: 0.0, through: 1_200.0, by: 1.0).map { videoTime in
            let subtitleTime = (videoTime - expectedVideoShift) / expectedVideoPerSubtitleRate
            return SubtitleSpeechSample(
                time: videoTime,
                probability: cueIsActive(cues, at: subtitleTime) ? 0.94 : 0.04
            )
        }
        let candidate = SubtitleCandidate(
            url: subtitleURL,
            format: .srt,
            encodingName: "UTF-8",
            cues: cues,
            fileSizeBytes: 16_000,
            score: SubtitleCandidateScorer().score(
                video: video,
                subtitleURL: subtitleURL,
                cues: cues
            )
        )

        let match = SubtitleCompatibilityMatcher.match(
            candidate: candidate,
            video: video,
            samples: samples
        )
        let transform = try XCTUnwrap(match.timingTransform)

        XCTAssertEqual(
            transform.offset,
            -expectedVideoShift / expectedVideoPerSubtitleRate,
            accuracy: 0.25
        )
        XCTAssertEqual(
            transform.rate,
            1 / expectedVideoPerSubtitleRate,
            accuracy: 0.000_35
        )
        XCTAssertGreaterThanOrEqual(match.confidence, 0.68)
        XCTAssertGreaterThanOrEqual(match.audioMatchScore ?? 0, 0.32)
    }

    func testCompatibilityMatcherDoesNotApplyCorrectionWithoutAudioVariation() throws {
        let folder = try makeTemporaryDirectory()
        let video = SubtitleSearchVideo(
            url: folder.appendingPathComponent("Pattern.Movie.2024.mp4"),
            duration: 1_200
        )
        let subtitleURL = folder.appendingPathComponent("Pattern.Movie.2024.srt")
        let cues = synchronizationCues()
        let candidate = SubtitleCandidate(
            url: subtitleURL,
            format: .srt,
            encodingName: "UTF-8",
            cues: cues,
            fileSizeBytes: 16_000,
            score: SubtitleCandidateScorer().score(
                video: video,
                subtitleURL: subtitleURL,
                cues: cues
            )
        )
        let samples = stride(from: 0.0, through: 1_200.0, by: 2.0).map {
            SubtitleSpeechSample(time: $0, probability: 0.5)
        }

        let match = SubtitleCompatibilityMatcher.match(
            candidate: candidate,
            video: video,
            samples: samples
        )

        XCTAssertNil(match.timingTransform)
        XCTAssertLessThan(match.audioMatchScore ?? 0, 0.32)
    }

    @MainActor
    func testResetSubtitleSynchronizationClearsAutomaticAndManualCorrections() {
        let suiteName = "SubtitleSynchronizationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = PlayerController(preferences: AppPreferences(defaults: defaults))
        controller.primaryTrack.cues = [SubtitleCue(start: 1, end: 2, text: "Cue")]
        controller.primaryTrack.offset = 1.5
        controller.primaryTrack.timingTransform = SubtitleTimingTransform(offset: 3, rate: 0.999)
        controller.primaryTrack.synchronizationState = .synchronized(confidence: 0.9)

        controller.resetSubtitleSynchronization(for: .primary)

        XCTAssertEqual(controller.primaryTrack.offset, 0)
        XCTAssertEqual(controller.primaryTrack.timingTransform, .identity)
        XCTAssertEqual(controller.primaryTrack.synchronizationState, .idle)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleCandidateFinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }

    private func subtitleText(lastStart: Int) -> String {
        """
        1
        00:00:10,000 --> 00:00:12,000
        First

        2
        \(timestamp(lastStart)) --> \(timestamp(lastStart + 3))
        Last
        """
    }

    private func webVTTText(lastStart: Int) -> String {
        """
        WEBVTT

        00:00:10.000 --> 00:00:12.000
        First

        \(timestamp(lastStart, separator: ".")) --> \(timestamp(lastStart + 3, separator: "."))
        Last
        """
    }

    private func generatedCues(count: Int, lastStart: Int) -> [SubtitleCue] {
        (0..<count).map { index in
            let fraction = Double(index) / Double(max(count - 1, 1))
            let start = 10 + (Double(lastStart) - 10) * fraction
            return SubtitleCue(start: start, end: start + 3, text: "Cue \(index)")
        }
    }

    private func synchronizationCues() -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        var start = 18.0
        var index = 0
        while start < 1_180 {
            let duration = 1.4 + Double((index * 7) % 6) * 0.45
            result.append(SubtitleCue(
                start: start,
                end: min(start + duration, 1_195),
                text: "Dialogue \(index)"
            ))
            start += 4.0 + Double((index * 11) % 17)
            index += 1
        }
        return result
    }

    private func cueIsActive(_ cues: [SubtitleCue], at time: TimeInterval) -> Bool {
        cues.contains { $0.start <= time && $0.end >= time }
    }

    private func timestamp(_ seconds: Int, separator: Character = ",") -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainder) + "\(separator)000"
    }
}
