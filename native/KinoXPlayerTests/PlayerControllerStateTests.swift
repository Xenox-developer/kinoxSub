import Foundation
import XCTest
@testable import KinoXPlayer

@MainActor
final class PlayerControllerStateTests: XCTestCase {
    func testStaleSubtitleAssignmentCannotReplaceNewerTrackMutation() throws {
        let context = try makeController()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let firstURL = try makeSubtitle(named: "first.srt", text: "First")
        let newerURL = try makeSubtitle(named: "newer.srt", text: "Newer")
        let staleURL = try makeSubtitle(named: "stale.srt", text: "Stale")

        context.controller.loadSubtitle(firstURL, into: .primary)
        let staleMutationID = context.controller.currentSubtitleMutationID(for: .primary)
        context.controller.loadSubtitle(newerURL, into: .primary)
        context.controller.loadSubtitle(
            staleURL,
            into: .primary,
            expectedSubtitleMutationID: staleMutationID
        )

        XCTAssertEqual(context.controller.primaryTrack.fileURL, newerURL)
        context.controller.clearTrack(.primary)
    }

    func testStaleVideoSessionCannotAssignSubtitleToNewMovie() throws {
        let context = try makeController()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let staleSessionID = context.controller.currentVideoSessionID
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KinoXPlayerStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let videoURL = directory.appendingPathComponent("new-film.mp4")
        try Data("placeholder".utf8).write(to: videoURL)
        let subtitleURL = try makeSubtitle(named: "old-film.srt", text: "Old")

        context.controller.openVideo(videoURL)
        XCTAssertEqual(
            context.controller.subtitleFolderURL?.lastPathComponent,
            OpenSubtitlesCache.movieFolderName(for: videoURL)
        )
        XCTAssertTrue(
            context.controller.subtitleFolderURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
        )
        context.controller.loadSubtitle(
            subtitleURL,
            into: .primary,
            expectedVideoSessionID: staleSessionID
        )

        XCTAssertNil(context.controller.primaryTrack.fileURL)
    }

    func testManualOffsetCancelsRunningAutomaticSynchronization() throws {
        let context = try makeController()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        context.controller.primaryTrack.cues = [
            SubtitleCue(start: 1, end: 2, text: "Hello")
        ]
        context.controller.primaryTrack.synchronizationState = .analyzing

        context.controller.adjustOffset(for: .primary, by: 0.2)

        XCTAssertEqual(context.controller.primaryTrack.offset, 0.2, accuracy: 0.001)
        XCTAssertEqual(context.controller.primaryTrack.synchronizationState, .idle)
    }

    func testPhraseLinkingNeverShowsUnverifiedSecondaryBesidePrimary() throws {
        let context = try makeController()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        context.preferences.phraseLinkingEnabled = true
        context.controller.primaryTrack.cues = [
            SubtitleCue(start: 1, end: 3, text: "Primary context")
        ]
        context.controller.secondaryTrack.cues = [
            SubtitleCue(start: 1, end: 3, text: "Unrelated secondary context")
        ]

        let protectedFrame = context.controller.subtitleDisplayFrame(at: 2)
        XCTAssertEqual(protectedFrame.primaryText, "Primary context")
        XCTAssertEqual(protectedFrame.secondaryText, "")

        context.controller.primaryTrack.isEnabled = false
        let secondaryOnlyFrame = context.controller.subtitleDisplayFrame(at: 2)
        XCTAssertEqual(secondaryOnlyFrame.primaryText, "")
        XCTAssertEqual(secondaryOnlyFrame.secondaryText, "Unrelated secondary context")
    }

    func testSubtitleLanesKeepTrackLevelsWhenOtherTrackIsEmpty() {
        let minimumSecondaryHeight = SubtitleLaneGeometry.minimumHeight(forFontSize: 23)
        let minimumPrimaryHeight = SubtitleLaneGeometry.minimumHeight(forFontSize: 30)
        let both = SubtitleLaneGeometry.layout(
            secondarySize: CGSize(width: 430, height: 68),
            primarySize: CGSize(width: 520, height: 86),
            containerWidth: 640,
            minimumSecondaryLaneHeight: minimumSecondaryHeight,
            minimumPrimaryLaneHeight: minimumPrimaryHeight,
            spacing: 24
        )
        let primaryOnly = SubtitleLaneGeometry.layout(
            secondarySize: .zero,
            primarySize: CGSize(width: 520, height: 86),
            containerWidth: 640,
            minimumSecondaryLaneHeight: minimumSecondaryHeight,
            minimumPrimaryLaneHeight: minimumPrimaryHeight,
            spacing: 24
        )
        let secondaryOnly = SubtitleLaneGeometry.layout(
            secondarySize: CGSize(width: 430, height: 68),
            primarySize: .zero,
            containerWidth: 640,
            minimumSecondaryLaneHeight: minimumSecondaryHeight,
            minimumPrimaryLaneHeight: minimumPrimaryHeight,
            spacing: 24
        )

        XCTAssertEqual(both.primary.maxY, primaryOnly.primary.maxY, accuracy: 0.001)
        XCTAssertEqual(both.secondary.maxY, secondaryOnly.secondary.maxY, accuracy: 0.001)
        XCTAssertEqual(both.primaryLane, primaryOnly.primaryLane)
        XCTAssertEqual(both.secondaryLane, secondaryOnly.secondaryLane)
        XCTAssertEqual(both.contentSize, primaryOnly.contentSize)
        XCTAssertEqual(both.contentSize, secondaryOnly.contentSize)
    }

    func testSubtitleLanesExpandForMultilineTextWithoutOverlap() {
        let geometry = SubtitleLaneGeometry.layout(
            secondarySize: CGSize(width: 620, height: 132),
            primarySize: CGSize(width: 590, height: 178),
            containerWidth: 640,
            minimumSecondaryLaneHeight: 76,
            minimumPrimaryLaneHeight: 96,
            spacing: 24
        )

        XCTAssertFalse(geometry.secondary.intersects(geometry.primary))
        XCTAssertEqual(
            geometry.primary.minY - geometry.secondary.maxY,
            24,
            accuracy: 0.001
        )
        XCTAssertEqual(geometry.secondary.midX, 320, accuracy: 0.001)
        XCTAssertEqual(geometry.primary.midX, 320, accuracy: 0.001)
    }

    func testSubtitleLaneResizeRecentersWithoutChangingVerticalLevels() {
        let narrow = SubtitleLaneGeometry.layout(
            secondarySize: CGSize(width: 300, height: 68),
            primarySize: CGSize(width: 330, height: 86),
            containerWidth: 480,
            minimumSecondaryLaneHeight: 76,
            minimumPrimaryLaneHeight: 96,
            spacing: 24
        )
        let wide = SubtitleLaneGeometry.layout(
            secondarySize: CGSize(width: 300, height: 68),
            primarySize: CGSize(width: 330, height: 86),
            containerWidth: 1_280,
            minimumSecondaryLaneHeight: 76,
            minimumPrimaryLaneHeight: 96,
            spacing: 24
        )

        XCTAssertEqual(narrow.secondary.minY, wide.secondary.minY, accuracy: 0.001)
        XCTAssertEqual(narrow.primary.minY, wide.primary.minY, accuracy: 0.001)
        XCTAssertEqual(narrow.secondary.midX, 240, accuracy: 0.001)
        XCTAssertEqual(wide.secondary.midX, 640, accuracy: 0.001)
        XCTAssertEqual(narrow.primary.midX, 240, accuracy: 0.001)
        XCTAssertEqual(wide.primary.midX, 640, accuracy: 0.001)
    }

    private func makeController() throws -> (
        controller: PlayerController,
        preferences: AppPreferences,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "KinoXPlayerTests.PlayerController.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let preferences = AppPreferences(defaults: defaults)
        let bindingStore = SubtitleBindingStore(defaults: defaults)
        let subtitleLibraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KinoXPlayerStateLibrary-\(UUID().uuidString)",
                isDirectory: true
            )
        let modelRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KinoXPlayerStateModels-\(UUID().uuidString)",
                isDirectory: true
            )
        let alignmentCacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KinoXPlayerStatePhraseCache-\(UUID().uuidString)",
                isDirectory: true
            )
        return (
            PlayerController(
                preferences: preferences,
                subtitleBindingStore: bindingStore,
                phraseAlignmentModels: PhraseAlignmentModelManager(rootURL: modelRoot),
                phraseAlignmentCache: PhraseAlignmentCache(rootURL: alignmentCacheRoot),
                subtitleFolderProvider: { videoURL in
                    try OpenSubtitlesCache.movieFolderURL(
                        for: videoURL,
                        rootURL: subtitleLibraryRoot
                    )
                }
            ),
            preferences,
            defaults,
            suiteName
        )
    }

    private func makeSubtitle(named name: String, text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KinoXPlayerStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("1\n00:00:01,000 --> 00:00:02,000\n\(text)\n".utf8).write(to: url)
        return url
    }
}
