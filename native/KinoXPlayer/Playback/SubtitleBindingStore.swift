import Foundation

struct PersistedSubtitleBinding: Codable, Equatable {
    let fileID: Int
    let displayName: String?
    let languageCode: String?
    let isEnabled: Bool
    let manualOffset: TimeInterval
    let timingOffset: TimeInterval
    let timingRate: Double
    let synchronizationConfidence: Double?

    init(
        fileID: Int,
        displayName: String?,
        languageCode: String? = nil,
        isEnabled: Bool,
        manualOffset: TimeInterval,
        timingOffset: TimeInterval,
        timingRate: Double,
        synchronizationConfidence: Double?
    ) {
        self.fileID = fileID
        self.displayName = displayName
        self.languageCode = languageCode
        self.isEnabled = isEnabled
        self.manualOffset = manualOffset
        self.timingOffset = timingOffset
        self.timingRate = timingRate
        self.synchronizationConfidence = synchronizationConfidence
    }
}

final class SubtitleBindingStore {
    private struct VideoBindings: Codable, Equatable {
        let videoPath: String
        var fileSize: Int64?
        var modificationDate: Date?
        var fileSystemNumber: Int64?
        var fileSystemFileNumber: Int64?
        var primary: PersistedSubtitleBinding?
        var secondary: PersistedSubtitleBinding?
        var updatedAt: Date

        var isEmpty: Bool { primary == nil && secondary == nil }

        func binding(for slot: SubtitleSlot) -> PersistedSubtitleBinding? {
            switch slot {
            case .primary: return primary
            case .secondary: return secondary
            }
        }

        mutating func set(
            _ binding: PersistedSubtitleBinding?,
            for slot: SubtitleSlot
        ) {
            switch slot {
            case .primary: primary = binding
            case .secondary: secondary = binding
            }
        }
    }

    private struct Library: Codable {
        var videos: [String: VideoBindings] = [:]
    }

    private struct VideoFingerprint {
        let path: String
        let fileSize: Int64?
        let modificationDate: Date?
        let fileSystemNumber: Int64?
        let fileSystemFileNumber: Int64?
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumVideoCount: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "videoSubtitleBindings.v1",
        maximumVideoCount: Int = 80
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumVideoCount = max(maximumVideoCount, 1)
    }

    func binding(
        for videoURL: URL,
        slot: SubtitleSlot
    ) -> PersistedSubtitleBinding? {
        let fingerprint = Self.fingerprint(for: videoURL)
        guard let video = loadLibrary().videos[fingerprint.path],
              Self.matches(video, fingerprint: fingerprint) else {
            return nil
        }
        return video.binding(for: slot)
    }

    func setBinding(
        _ binding: PersistedSubtitleBinding,
        for videoURL: URL,
        slot: SubtitleSlot
    ) {
        let fingerprint = Self.fingerprint(for: videoURL)
        var library = loadLibrary()
        var video: VideoBindings
        if let existing = library.videos[fingerprint.path],
           Self.matches(existing, fingerprint: fingerprint) {
            video = existing
        } else {
            video = VideoBindings(
                videoPath: fingerprint.path,
                fileSize: fingerprint.fileSize,
                modificationDate: fingerprint.modificationDate,
                fileSystemNumber: fingerprint.fileSystemNumber,
                fileSystemFileNumber: fingerprint.fileSystemFileNumber,
                primary: nil,
                secondary: nil,
                updatedAt: Date()
            )
        }
        video.fileSize = fingerprint.fileSize
        video.modificationDate = fingerprint.modificationDate
        video.fileSystemNumber = fingerprint.fileSystemNumber
        video.fileSystemFileNumber = fingerprint.fileSystemFileNumber
        video.set(binding, for: slot)
        video.updatedAt = Date()
        library.videos[fingerprint.path] = video
        prune(&library)
        save(library)
    }

    func removeBinding(for videoURL: URL, slot: SubtitleSlot) {
        let path = Self.standardizedPath(for: videoURL)
        var library = loadLibrary()
        guard var video = library.videos[path] else { return }
        video.set(nil, for: slot)
        if video.isEmpty {
            library.videos[path] = nil
        } else {
            video.updatedAt = Date()
            library.videos[path] = video
        }
        save(library)
    }

    private func loadLibrary() -> Library {
        guard let data = defaults.data(forKey: storageKey),
              let library = try? JSONDecoder().decode(Library.self, from: data) else {
            return Library()
        }
        return library
    }

    private func save(_ library: Library) {
        guard let data = try? JSONEncoder().encode(library) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func prune(_ library: inout Library) {
        guard library.videos.count > maximumVideoCount else { return }
        let pathsToRemove = library.videos.values
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(library.videos.count - maximumVideoCount)
            .map(\.videoPath)
        for path in pathsToRemove {
            library.videos[path] = nil
        }
    }

    private static func matches(
        _ stored: VideoBindings,
        fingerprint current: VideoFingerprint
    ) -> Bool {
        guard stored.videoPath == current.path else { return false }
        if let storedSize = stored.fileSize,
           let currentSize = current.fileSize,
           storedSize != currentSize {
            return false
        }
        if let storedDate = stored.modificationDate,
           let currentDate = current.modificationDate,
           abs(storedDate.timeIntervalSince(currentDate)) > 1 {
            return false
        }
        if let storedSystem = stored.fileSystemNumber,
           let currentSystem = current.fileSystemNumber,
           storedSystem != currentSystem {
            return false
        }
        if let storedFile = stored.fileSystemFileNumber,
           let currentFile = current.fileSystemFileNumber,
           storedFile != currentFile {
            return false
        }
        return true
    }

    private static func fingerprint(for videoURL: URL) -> VideoFingerprint {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: videoURL.standardizedFileURL.path
        )
        return VideoFingerprint(
            path: standardizedPath(for: videoURL),
            fileSize: (attributes?[.size] as? NSNumber)?.int64Value,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileSystemNumber: (attributes?[.systemNumber] as? NSNumber)?.int64Value,
            fileSystemFileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.int64Value
        )
    }

    private static func standardizedPath(for videoURL: URL) -> String {
        videoURL.standardizedFileURL.path
    }
}
