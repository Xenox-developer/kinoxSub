import Foundation
import XCTest
@testable import KinoXPlayer

final class SubtitleBindingStoreTests: XCTestCase {
    func testBindingsSurviveNewStoreAndRemainIndependentForBothSlots() throws {
        let suiteName = "KinoXPlayerTests.SubtitleBindings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let videoURL = try makeVideoFile(named: "film.mp4", contents: "video-one")
        let anotherVideoURL = try makeVideoFile(named: "other.mp4", contents: "video-two")
        let primary = makeBinding(fileID: 11, displayName: "Русские.srt", offset: 0.4)
        let secondary = makeBinding(fileID: 22, displayName: "Deutsch.srt", offset: -0.2)

        var store: SubtitleBindingStore? = SubtitleBindingStore(defaults: defaults)
        store?.setBinding(primary, for: videoURL, slot: .primary)
        store?.setBinding(secondary, for: videoURL, slot: .secondary)
        store = nil

        let reopenedStore = SubtitleBindingStore(defaults: defaults)
        XCTAssertEqual(reopenedStore.binding(for: videoURL, slot: .primary), primary)
        XCTAssertEqual(reopenedStore.binding(for: videoURL, slot: .secondary), secondary)
        XCTAssertNil(reopenedStore.binding(for: anotherVideoURL, slot: .primary))
    }

    func testRemovingOneSlotDoesNotRemoveTheOther() throws {
        let suiteName = "KinoXPlayerTests.SubtitleBindings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let videoURL = try makeVideoFile(named: "film.mp4", contents: "video")
        let store = SubtitleBindingStore(defaults: defaults)
        let primary = makeBinding(fileID: 1, displayName: "S1.srt", offset: 0)
        let secondary = makeBinding(fileID: 2, displayName: "S2.srt", offset: 0)
        store.setBinding(primary, for: videoURL, slot: .primary)
        store.setBinding(secondary, for: videoURL, slot: .secondary)

        store.removeBinding(for: videoURL, slot: .primary)

        XCTAssertNil(store.binding(for: videoURL, slot: .primary))
        XCTAssertEqual(store.binding(for: videoURL, slot: .secondary), secondary)
    }

    func testBindingIsNotRestoredWhenVideoAtSamePathWasReplaced() throws {
        let suiteName = "KinoXPlayerTests.SubtitleBindings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let videoURL = try makeVideoFile(named: "replaceable.mp4", contents: "old")
        let store = SubtitleBindingStore(defaults: defaults)
        store.setBinding(
            makeBinding(fileID: 77, displayName: "Old.srt", offset: 0),
            for: videoURL,
            slot: .primary
        )
        store.setBinding(
            makeBinding(fileID: 78, displayName: "Old S2.srt", offset: 0),
            for: videoURL,
            slot: .secondary
        )

        let originalModificationDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: videoURL.path)[.modificationDate] as? Date
        )
        try Data("new".utf8).write(to: videoURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: videoURL.path
        )

        XCTAssertNil(store.binding(for: videoURL, slot: .primary))
        store.setBinding(
            makeBinding(fileID: 79, displayName: "New.srt", offset: 0),
            for: videoURL,
            slot: .primary
        )
        XCTAssertEqual(store.binding(for: videoURL, slot: .primary)?.fileID, 79)
        XCTAssertNil(store.binding(for: videoURL, slot: .secondary))
    }

    private func makeBinding(
        fileID: Int,
        displayName: String,
        offset: TimeInterval
    ) -> PersistedSubtitleBinding {
        PersistedSubtitleBinding(
            fileID: fileID,
            displayName: displayName,
            isEnabled: true,
            manualOffset: offset,
            timingOffset: 1.25,
            timingRate: 0.999,
            synchronizationConfidence: 0.91
        )
    }

    private func makeVideoFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KinoXPlayerBindingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
