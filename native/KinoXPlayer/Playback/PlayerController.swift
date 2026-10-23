import AppKit
import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import UniformTypeIdentifiers

@MainActor
final class PlayerController: ObservableObject {
    typealias SubtitleFolderProvider = (URL) throws -> URL

    enum LoadingState: Equatable {
        case empty
        case loading(String)
        case ready
        case failed(String)
    }

    let player = AVPlayer()

    @Published private(set) var loadingState: LoadingState = .empty
    @Published private(set) var videoURL: URL?
    @Published private(set) var videoName: String?
    @Published private(set) var subtitleFolderURL: URL?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackRate: Float = 1
    @Published var primaryTrack = SubtitleTrack(slot: .primary)
    @Published var secondaryTrack = SubtitleTrack(slot: .secondary)
    @Published var hudMessage: String?
    @Published var isDropTargeted = false
    @Published var isSidebarVisible: Bool
    @Published private(set) var phraseAlignmentState: SubtitlePhraseAlignmentState = .idle
    @Published private(set) var phraseModelState: PhraseAlignmentModelManager.State

    private let preferences: AppPreferences
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var activeSecurityScopedVideoURL: URL?
    private var selectedPlaybackRate: Float
    private var lastPersistedPosition: TimeInterval = 0
    private var hudTask: Task<Void, Never>?
    private var subtitleLoadIDs: [SubtitleSlot: UUID] = [:]
    private var subtitleSynchronizationIDs: [SubtitleSlot: UUID] = [:]
    private var subtitleSynchronizationTasks: [SubtitleSlot: Task<Void, Never>] = [:]
    private let subtitleSearchService = LocalSubtitleSearchService()
    private let subtitleBindingStore: SubtitleBindingStore
    private let subtitleFolderProvider: SubtitleFolderProvider
    let phraseAlignmentModels: PhraseAlignmentModelManager
    private let phraseAlignmentCache: PhraseAlignmentCache
    private var videoSessionID = UUID()
    private var restoredVideoSessionID: UUID?
    private var subtitleMutationIDs: [SubtitleSlot: UUID] = [:]
    private var subtitleRestoreTokens: [SubtitleSlot: UUID] = [:]
    private var phraseAlignment: SubtitlePhraseAlignment?
    private var phraseAlignmentTask: Task<Void, Never>?
    private var phraseAlignmentGeneration = UUID()
    private var cancellables: Set<AnyCancellable> = []

    init(
        preferences: AppPreferences,
        subtitleBindingStore: SubtitleBindingStore = SubtitleBindingStore(),
        phraseAlignmentModels: PhraseAlignmentModelManager = .shared,
        phraseAlignmentCache: PhraseAlignmentCache = PhraseAlignmentCache(),
        subtitleFolderProvider: @escaping SubtitleFolderProvider = {
            try OpenSubtitlesCache.movieFolderURL(for: $0)
        }
    ) {
        self.preferences = preferences
        self.subtitleBindingStore = subtitleBindingStore
        self.phraseAlignmentModels = phraseAlignmentModels
        self.phraseAlignmentCache = phraseAlignmentCache
        self.phraseModelState = phraseAlignmentModels.state
        self.subtitleFolderProvider = subtitleFolderProvider
        self.selectedPlaybackRate = Float(preferences.defaultPlaybackRate)
        self.playbackRate = Float(preferences.defaultPlaybackRate)
        self.isSidebarVisible = preferences.showSidebarOnLaunch
        for slot in SubtitleSlot.allCases {
            subtitleMutationIDs[slot] = UUID()
        }

        player.volume = Float(preferences.rememberVolume ? preferences.lastVolume : 0.8)
        observePhraseAlignmentSettings()
        installObservers()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        for task in subtitleSynchronizationTasks.values {
            task.cancel()
        }
        phraseAlignmentTask?.cancel()
        activeSecurityScopedVideoURL?.stopAccessingSecurityScopedResource()
    }

    var hasVideo: Bool { videoURL != nil }
    var isVideoReady: Bool { loadingState == .ready }
    var currentVideoSessionID: UUID { videoSessionID }

    func currentSubtitleMutationID(for slot: SubtitleSlot) -> UUID? {
        subtitleMutationIDs[slot]
    }

    var progress: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var formattedTime: String {
        "\(Self.formatTime(currentTime)) / \(Self.formatTime(duration))"
    }

    func track(for slot: SubtitleSlot) -> SubtitleTrack {
        switch slot {
        case .primary: return primaryTrack
        case .secondary: return secondaryTrack
        }
    }

    func subtitleDisplayFrame(at playbackTime: TimeInterval) -> SubtitleDisplayFrame {
        let primary = primaryTrack
        let secondary = secondaryTrack

        guard preferences.phraseLinkingEnabled else {
            return independentSubtitleDisplayFrame(at: playbackTime)
        }

        if !primary.isEnabled || !primary.isLoaded {
            return SubtitleDisplayFrame(
                primaryText: "",
                secondaryText: secondary.activeText(at: playbackTime),
                isAlignedPair: false,
                confidence: nil
            )
        }
        if !secondary.isEnabled || !secondary.isLoaded {
            return SubtitleDisplayFrame(
                primaryText: primary.activeText(at: playbackTime),
                secondaryText: "",
                isAlignedPair: false,
                confidence: nil
            )
        }

        if case .aligned = phraseAlignmentState, let phraseAlignment {
            return phraseAlignment.displayFrame(at: playbackTime)
        }

        // Until the semantic result is ready, never place an unrelated S2 line
        // next to S1. The movie remains usable while analysis continues.
        return SubtitleDisplayFrame(
            primaryText: primary.activeText(at: playbackTime),
            secondaryText: "",
            isAlignedPair: false,
            confidence: nil
        )
    }

    func installPhraseAlignmentModel() {
        phraseAlignmentModels.install()
    }

    func cancelPhraseAlignmentModelInstallation() {
        phraseAlignmentModels.cancelInstallation()
    }

    func removePhraseAlignmentModel() {
        preferences.phraseLinkingEnabled = false
        invalidatePhraseAlignment(state: .unavailable("Локальная модель не установлена"))
        phraseAlignmentModels.removeModel()
    }

    func rebuildPhraseAlignment() {
        schedulePhraseAlignmentRebuild(delayNanoseconds: 0)
    }

    private func independentSubtitleDisplayFrame(
        at playbackTime: TimeInterval
    ) -> SubtitleDisplayFrame {
        SubtitleDisplayFrame(
            primaryText: primaryTrack.activeText(at: playbackTime),
            secondaryText: secondaryTrack.activeText(at: playbackTime),
            isAlignedPair: false,
            confidence: nil
        )
    }

    private func observePhraseAlignmentSettings() {
        phraseAlignmentModels.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                let previousState = self.phraseModelState
                self.phraseModelState = state
                if state == .ready, previousState != .ready {
                    // A completed explicit installation enables the feature once.
                    // An already installed model at app launch does not override a
                    // user's later choice to keep phrase linking disabled.
                    self.preferences.phraseLinkingEnabled = true
                }
                if state == .ready, self.preferences.phraseLinkingEnabled {
                    self.schedulePhraseAlignmentRebuild(delayNanoseconds: 0)
                } else {
                    self.invalidatePhraseAlignment(
                        state: self.phraseAlignmentUnavailableState(for: state)
                    )
                }
            }
            .store(in: &cancellables)

        preferences.$phraseLinkingEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                if isEnabled {
                    self.schedulePhraseAlignmentRebuild(delayNanoseconds: 0)
                } else {
                    self.invalidatePhraseAlignment(state: .idle)
                }
            }
            .store(in: &cancellables)
    }

    private func phraseAlignmentUnavailableState(
        for modelState: PhraseAlignmentModelManager.State
    ) -> SubtitlePhraseAlignmentState {
        switch modelState {
        case .ready:
            return preferences.phraseLinkingEnabled ? .waitingForTracks : .idle
        case .notInstalled:
            return .unavailable("Локальная языковая модель не установлена")
        case .downloading:
            return .unavailable("Языковая модель загружается")
        case .compiling:
            return .unavailable("Языковая модель подготавливается")
        case .failed(let message):
            return .unavailable(message)
        }
    }

    private func invalidatePhraseAlignment(state: SubtitlePhraseAlignmentState) {
        phraseAlignmentGeneration = UUID()
        phraseAlignmentTask?.cancel()
        phraseAlignmentTask = nil
        phraseAlignment = nil
        phraseAlignmentState = state
    }

    private func schedulePhraseAlignmentRebuild(
        delayNanoseconds: UInt64 = 300_000_000
    ) {
        guard preferences.phraseLinkingEnabled else {
            invalidatePhraseAlignment(state: .idle)
            return
        }
        guard phraseAlignmentModels.isReady else {
            invalidatePhraseAlignment(
                state: phraseAlignmentUnavailableState(for: phraseAlignmentModels.state)
            )
            return
        }

        let primary = primaryTrack
        let secondary = secondaryTrack
        guard primary.isLoaded, secondary.isLoaded else {
            invalidatePhraseAlignment(state: .waitingForTracks)
            return
        }
        if primary.synchronizationState == .analyzing
            || secondary.synchronizationState == .analyzing {
            invalidatePhraseAlignment(state: .waitingForSynchronization)
            return
        }

        let generation = UUID()
        let sessionID = videoSessionID
        let primaryMutationID = subtitleMutationIDs[.primary]
        let secondaryMutationID = subtitleMutationIDs[.secondary]
        phraseAlignmentGeneration = generation
        phraseAlignmentTask?.cancel()
        phraseAlignment = nil

        let primaryCues = primary.cues
        let secondaryCues = secondary.cues
        let primaryTransform = primary.timingTransform
        let secondaryTransform = secondary.timingTransform
        let primaryOffset = primary.offset
        let secondaryOffset = secondary.offset
        let primaryLanguageCode = primary.languageCode
        let secondaryLanguageCode = secondary.languageCode
        let modelVersion = PhraseAlignmentModelManifest.modelVersion

        phraseAlignmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                try Task.checkCancellation()
                guard self.isPhraseAlignmentContextCurrent(
                    generation: generation,
                    sessionID: sessionID,
                    primaryMutationID: primaryMutationID,
                    secondaryMutationID: secondaryMutationID,
                    primaryCues: primaryCues,
                    secondaryCues: secondaryCues,
                    primaryTransform: primaryTransform,
                    secondaryTransform: secondaryTransform,
                    primaryOffset: primaryOffset,
                    secondaryOffset: secondaryOffset,
                    primaryLanguageCode: primaryLanguageCode,
                    secondaryLanguageCode: secondaryLanguageCode
                ) else {
                    return
                }

                self.phraseAlignmentState = .analyzing
                let cacheKey = await Task.detached(priority: .utility) {
                    PhraseAlignmentCache.makeKey(
                        primaryCues: primaryCues,
                        primaryTransform: primaryTransform,
                        primaryOffset: primaryOffset,
                        primaryLanguageCode: primaryLanguageCode,
                        secondaryCues: secondaryCues,
                        secondaryTransform: secondaryTransform,
                        secondaryOffset: secondaryOffset,
                        secondaryLanguageCode: secondaryLanguageCode,
                        modelVersion: modelVersion
                    )
                }.value
                try Task.checkCancellation()

                let result: SubtitlePhraseAlignment
                if let cached = await self.phraseAlignmentCache.alignment(forKey: cacheKey),
                   cached.modelVersion == modelVersion {
                    result = cached
                } else {
                    let baseProvider = try await self.phraseAlignmentModels.makeEmbeddingProvider()
                    let provider = CachedPhraseEmbeddingProvider(base: baseProvider)
                    result = try await SubtitlePhraseAligner(
                        embeddingProvider: provider
                    ).align(
                        primaryCues: primaryCues,
                        secondaryCues: secondaryCues,
                        primaryTimingTransform: primaryTransform,
                        primaryManualOffset: primaryOffset,
                        secondaryTimingTransform: secondaryTransform,
                        secondaryManualOffset: secondaryOffset,
                        primaryLanguageCode: primaryLanguageCode,
                        secondaryLanguageCode: secondaryLanguageCode
                    )
                    try Task.checkCancellation()
                    // The cache is an optimization only. A full semantic result
                    // must remain usable when Application Support is read-only,
                    // full, or temporarily unavailable.
                    try? await self.phraseAlignmentCache.store(result, forKey: cacheKey)
                }

                guard self.isPhraseAlignmentContextCurrent(
                    generation: generation,
                    sessionID: sessionID,
                    primaryMutationID: primaryMutationID,
                    secondaryMutationID: secondaryMutationID,
                    primaryCues: primaryCues,
                    secondaryCues: secondaryCues,
                    primaryTransform: primaryTransform,
                    secondaryTransform: secondaryTransform,
                    primaryOffset: primaryOffset,
                    secondaryOffset: secondaryOffset,
                    primaryLanguageCode: primaryLanguageCode,
                    secondaryLanguageCode: secondaryLanguageCode
                ) else {
                    return
                }
                self.phraseAlignment = result
                self.phraseAlignmentState = .aligned(result.summary)
                self.phraseAlignmentTask = nil
            } catch is CancellationError {
                // A newer subtitle/video/timing generation owns the visible state.
            } catch {
                guard self.phraseAlignmentGeneration == generation else { return }
                self.phraseAlignment = nil
                self.phraseAlignmentState = .failed(error.localizedDescription)
                self.phraseAlignmentTask = nil
            }
        }
    }

    private func isPhraseAlignmentContextCurrent(
        generation: UUID,
        sessionID: UUID,
        primaryMutationID: UUID?,
        secondaryMutationID: UUID?,
        primaryCues: [SubtitleCue],
        secondaryCues: [SubtitleCue],
        primaryTransform: SubtitleTimingTransform,
        secondaryTransform: SubtitleTimingTransform,
        primaryOffset: TimeInterval,
        secondaryOffset: TimeInterval,
        primaryLanguageCode: String?,
        secondaryLanguageCode: String?
    ) -> Bool {
        phraseAlignmentGeneration == generation
            && videoSessionID == sessionID
            && subtitleMutationIDs[.primary] == primaryMutationID
            && subtitleMutationIDs[.secondary] == secondaryMutationID
            && primaryTrack.cues == primaryCues
            && secondaryTrack.cues == secondaryCues
            && primaryTrack.timingTransform == primaryTransform
            && secondaryTrack.timingTransform == secondaryTransform
            && primaryTrack.offset == primaryOffset
            && secondaryTrack.offset == secondaryOffset
            && primaryTrack.languageCode == primaryLanguageCode
            && secondaryTrack.languageCode == secondaryLanguageCode
            && preferences.phraseLinkingEnabled
            && phraseAlignmentModels.isReady
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "Открыть видео"
        panel.prompt = "Открыть"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.openVideo(url) }
        }
    }

    func chooseSubtitle(for slot: SubtitleSlot) {
        let expectedVideoSessionID = videoSessionID
        let expectedSubtitleMutationID = subtitleMutationIDs[slot]
        let initialDirectoryURL = ensureSubtitleFolderForCurrentVideo()
        let panel = NSOpenPanel()
        panel.title = "Загрузить \(slot.shortTitle)"
        panel.prompt = "Загрузить"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = initialDirectoryURL
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.loadSubtitle(
                    url,
                    into: slot,
                    expectedVideoSessionID: expectedVideoSessionID,
                    expectedSubtitleMutationID: expectedSubtitleMutationID
                )
            }
        }
    }

    func openVideo(_ url: URL) {
        guard Self.isVideoURL(url) else {
            if Self.isSubtitleURL(url) {
                loadSubtitle(url, into: firstAvailableSubtitleSlot())
            } else {
                let message = "Формат .\(url.pathExtension.lowercased()) не поддерживается системным AVPlayer."
                if hasVideo {
                    showHUD(message)
                } else {
                    loadingState = .failed(message)
                }
            }
            return
        }

        invalidatePhraseAlignment(
            state: preferences.phraseLinkingEnabled ? .waitingForTracks : .idle
        )

        let carriedTracks: [(SubtitleSlot, SubtitleTrack)] = videoURL == nil
            ? SubtitleSlot.allCases.compactMap { slot in
                let subtitle = track(for: slot)
                guard subtitle.fileURL != nil,
                      subtitle.isLoading || subtitle.isLoaded else {
                    return nil
                }
                return (slot, subtitle)
            }
            : []

        persistCurrentPosition(force: true)
        player.pause()
        itemStatusObservation = nil
        activeSecurityScopedVideoURL?.stopAccessingSecurityScopedResource()
        videoSessionID = UUID()
        restoredVideoSessionID = nil
        for slot in SubtitleSlot.allCases {
            cancelSubtitleSynchronization(for: slot)
            subtitleLoadIDs[slot] = nil
            let restoreToken = UUID()
            subtitleMutationIDs[slot] = restoreToken
            subtitleRestoreTokens[slot] = restoreToken
            updateTrack(slot) { track in
                track = SubtitleTrack(slot: slot)
            }
        }

        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedVideoURL = url
        } else {
            activeSecurityScopedVideoURL = nil
        }

        videoURL = url
        videoName = url.deletingPathExtension().lastPathComponent
        _ = ensureSubtitleFolderForCurrentVideo()
        loadingState = .loading(url.lastPathComponent)
        currentTime = 0
        duration = 0
        lastPersistedPosition = 0

        let currentSessionID = videoSessionID
        for (slot, subtitle) in carriedTracks {
            guard let subtitleURL = subtitle.fileURL else { continue }
            loadSubtitle(
                subtitleURL,
                into: slot,
                displayName: subtitle.fileName,
                languageCode: subtitle.languageCode,
                timingTransform: subtitle.timingTransform,
                synchronizationConfidence: nil,
                manualOffset: subtitle.offset,
                isEnabled: subtitle.isEnabled,
                expectedVideoSessionID: currentSessionID
            )
        }

        let item = AVPlayerItem(url: url)
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            guard let controller = self, let item else { return }
            Task { @MainActor in
                controller.handleItemStatus(item)
            }
        }
        player.replaceCurrentItem(with: item)
    }

    func loadSubtitle(
        _ url: URL,
        into slot: SubtitleSlot,
        displayName: String? = nil,
        languageCode: String? = nil,
        timingTransform: SubtitleTimingTransform = .identity,
        synchronizationConfidence: Double? = nil,
        manualOffset: TimeInterval = 0,
        isEnabled: Bool = true,
        expectedVideoSessionID: UUID? = nil,
        expectedSubtitleMutationID: UUID? = nil
    ) {
        guard expectedVideoSessionID == nil || expectedVideoSessionID == videoSessionID else {
            showHUD("Фильм изменился — выберите субтитры заново")
            return
        }
        guard expectedSubtitleMutationID == nil
                || expectedSubtitleMutationID == subtitleMutationIDs[slot] else {
            showHUD("\(slot.shortTitle) уже изменены — старый результат не применён")
            return
        }
        beginSubtitleLoad(
            url,
            into: slot,
            displayName: displayName,
            languageCode: languageCode,
            timingTransform: timingTransform,
            synchronizationConfidence: synchronizationConfidence,
            manualOffset: manualOffset,
            isEnabled: isEnabled,
            isRestoringBinding: false
        )
    }

    private func beginSubtitleLoad(
        _ url: URL,
        into slot: SubtitleSlot,
        displayName: String?,
        languageCode: String?,
        timingTransform: SubtitleTimingTransform,
        synchronizationConfidence: Double?,
        manualOffset: TimeInterval,
        isEnabled: Bool,
        isRestoringBinding: Bool
    ) {
        let loadID = UUID()
        let loadVideoURL = videoURL
        let loadVideoSessionID = videoSessionID
        cancelSubtitleSynchronization(for: slot)
        subtitleLoadIDs[slot] = loadID
        subtitleMutationIDs[slot] = loadID
        updateTrack(slot) { track in
            track.isLoading = true
            track.errorMessage = nil
            track.fileURL = url
            track.fileName = SubtitleFileActions.safeSuggestedFileName(
                displayName,
                sourceURL: url
            )
            track.encodingName = nil
            track.languageCode = languageCode?.lowercased()
            track.cues = []
            track.isEnabled = isEnabled
            track.offset = min(max(manualOffset, -120), 120)
            track.timingTransform = timingTransform
            track.synchronizationState = timingTransform == .identity
                ? .idle
                : .synchronized(confidence: synchronizationConfidence)
        }
        invalidatePhraseAlignment(
            state: preferences.phraseLinkingEnabled ? .waitingForTracks : .idle
        )

        Task { [weak self] in
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let parsed = try SubtitleParser.parse(data: Data(contentsOf: url))
                    var effectiveURL = url
                    if let loadVideoURL,
                       let location = OpenSubtitlesCache.persistentArtifactLocation(for: url),
                       location.movieFolderName
                        != OpenSubtitlesCache.movieFolderName(for: loadVideoURL),
                       let migratedURL = try? OpenSubtitlesCache.copyArtifactToMovieFolder(
                        fileID: location.fileID,
                        cues: parsed.cues,
                        toMovieFolderFor: loadVideoURL
                       ) {
                        effectiveURL = migratedURL
                    }
                    let resolvedLanguageCode = languageCode?.lowercased()
                        ?? Self.inferredSubtitleLanguage(from: parsed.cues)
                    return (
                        parsed: parsed,
                        fileURL: effectiveURL,
                        languageCode: resolvedLanguageCode
                    )
                }.value
                let parsed = result.parsed
                guard !parsed.cues.isEmpty else {
                    throw SubtitleParserError.noCues
                }

                guard let self,
                      self.subtitleLoadIDs[slot] == loadID,
                      self.subtitleMutationIDs[slot] == loadID,
                      self.videoSessionID == loadVideoSessionID,
                      self.videoURL == loadVideoURL else {
                    return
                }
                self.updateTrack(slot) { track in
                    track.fileURL = result.fileURL
                    track.cues = parsed.cues
                    track.encodingName = parsed.encodingName
                    track.languageCode = result.languageCode
                    track.isLoading = false
                    track.errorMessage = nil
                }
                if !isRestoringBinding, let loadVideoURL {
                    let resultLocation = OpenSubtitlesCache.persistentArtifactLocation(
                        for: result.fileURL
                    )
                    let expectedFolderName = OpenSubtitlesCache.movieFolderName(
                        for: loadVideoURL
                    )
                    if resultLocation == nil
                        || (resultLocation?.movieFolderName != nil
                            && resultLocation?.movieFolderName != expectedFolderName) {
                        self.subtitleBindingStore.removeBinding(for: loadVideoURL, slot: slot)
                    }
                }
                self.persistSubtitleBinding(for: slot)
                self.showHUD(
                    isRestoringBinding
                        ? "\(slot.shortTitle): восстановлены для этого фильма"
                        : "\(slot.shortTitle): загружено \(parsed.cues.count) реплик"
                )
                if self.track(for: slot).timingTransform == .identity,
                   self.preferences.automaticallySynchronizeSubtitles,
                   self.videoURL != nil,
                   self.loadingState == .ready {
                    self.synchronizeSubtitle(for: slot)
                }
                self.schedulePhraseAlignmentRebuild()
            } catch {
                guard let self,
                      self.subtitleLoadIDs[slot] == loadID,
                      self.subtitleMutationIDs[slot] == loadID,
                      self.videoSessionID == loadVideoSessionID,
                      self.videoURL == loadVideoURL else {
                    return
                }
                self.updateTrack(slot) { track in
                    track.cues = []
                    track.encodingName = nil
                    track.isLoading = false
                    track.synchronizationState = .idle
                    track.errorMessage = error.localizedDescription
                    if isRestoringBinding {
                        track.fileURL = nil
                        track.fileName = nil
                    }
                }
                if isRestoringBinding, let loadVideoURL {
                    self.subtitleBindingStore.removeBinding(for: loadVideoURL, slot: slot)
                }
                self.showHUD(
                    isRestoringBinding
                        ? "\(slot.shortTitle): сохранённый файл больше недоступен"
                        : "\(slot.shortTitle): не удалось прочитать субтитры"
                )
                self.schedulePhraseAlignmentRebuild()
            }
        }
    }

    func revealSubtitleFile(for slot: SubtitleSlot) {
        guard let fileURL = track(for: slot).fileURL else {
            showHUD("Сначала загрузите \(slot.shortTitle)")
            return
        }
        do {
            try SubtitleFileActions.revealInFinder(fileURL)
        } catch {
            showHUD(error.localizedDescription)
        }
    }

    func saveSubtitleCopy(for slot: SubtitleSlot) {
        let subtitleTrack = track(for: slot)
        guard let fileURL = subtitleTrack.fileURL, subtitleTrack.isLoaded else {
            showHUD("Сначала загрузите \(slot.shortTitle)")
            return
        }
        SubtitleFileActions.presentSaveCopy(
            of: fileURL,
            suggestedName: subtitleTrack.fileName,
            initialDirectoryURL: subtitleFolderURL
        ) { [weak self] result in
            switch result {
            case .success(let destinationURL?):
                self?.showHUD("\(slot.shortTitle): копия сохранена — \(destinationURL.lastPathComponent)")
            case .success(nil):
                break
            case .failure(let error):
                self?.showHUD("\(slot.shortTitle): \(error.localizedDescription)")
            }
        }
    }

    func openSubtitleLibrary() {
        do {
            let folderURL = try SubtitleFileActions.openDownloadedSubtitlesFolder(
                for: videoURL
            )
            if videoURL == nil {
                showHUD("Открыта постоянная медиатека субтитров")
            } else {
                showHUD("Открыта папка «\(folderURL.lastPathComponent)»")
            }
        } catch {
            showHUD(error.localizedDescription)
        }
    }

    @discardableResult
    func ensureSubtitleFolderForCurrentVideo() -> URL? {
        guard let videoURL else { return nil }
        do {
            let folderURL = try subtitleFolderProvider(videoURL)
            subtitleFolderURL = folderURL
            return folderURL
        } catch {
            subtitleFolderURL = nil
            showHUD("Не удалось создать папку субтитров для этого фильма")
            return nil
        }
    }

    func searchSubtitleCandidates(
        in folderURL: URL,
        expectedVideoSessionID: UUID? = nil
    ) async throws -> [SubtitleSearchMatch] {
        guard expectedVideoSessionID == nil || expectedVideoSessionID == videoSessionID else {
            throw CancellationError()
        }
        guard let videoURL else { throw SubtitleCompatibilityError.noVideo }
        let searchedVideoURL = videoURL
        let searchedVideoSessionID = videoSessionID
        let searchVideo = await makeSubtitleSearchVideo(for: searchedVideoURL)
        let matches = try await subtitleSearchService.search(
            in: folderURL,
            for: searchVideo,
            options: SubtitleSearchOptions(recursive: false)
        )
        guard videoURL == searchedVideoURL,
              videoSessionID == searchedVideoSessionID else {
            throw CancellationError()
        }
        return matches
    }

    func synchronizeSubtitle(for slot: SubtitleSlot) {
        guard let synchronizedVideoURL = videoURL else {
            showHUD("Сначала откройте видео")
            return
        }

        let subtitle = track(for: slot)
        guard subtitle.isLoaded, let subtitleURL = subtitle.fileURL else {
            showHUD("Сначала загрузите \(slot.shortTitle)")
            return
        }
        if case .analyzing = subtitle.synchronizationState { return }

        let synchronizationID = UUID()
        cancelSubtitleSynchronization(for: slot)
        subtitleSynchronizationIDs[slot] = synchronizationID
        updateTrack(slot) { $0.synchronizationState = .analyzing }
        invalidatePhraseAlignment(
            state: preferences.phraseLinkingEnabled
                ? .waitingForSynchronization
                : .idle
        )
        showHUD("\(slot.shortTitle): подгоняю к речи…")

        let cues = subtitle.cues
        let encodingName = subtitle.encodingName ?? "авто"
        subtitleSynchronizationTasks[slot] = Task { [weak self] in
            guard let self else { return }

            do {
                let searchVideo = await self.makeSubtitleSearchVideo(for: synchronizedVideoURL)
                try Task.checkCancellation()

                let score = SubtitleCandidateScorer().score(
                    video: searchVideo,
                    subtitleURL: subtitleURL,
                    cues: cues
                )
                let fileSize = (try? subtitleURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize) ?? 0
                let candidate = SubtitleCandidate(
                    url: subtitleURL,
                    format: SubtitleFileFormat(fileURL: subtitleURL) ?? .srt,
                    encodingName: encodingName,
                    cues: cues,
                    fileSizeBytes: fileSize,
                    score: score
                )
                let match = try await self.subtitleSearchService.synchronize(
                    candidate: candidate,
                    with: searchVideo
                )
                try Task.checkCancellation()

                guard self.videoURL == synchronizedVideoURL,
                      self.subtitleLoadIDs[slot] != nil,
                      self.track(for: slot).fileURL == subtitleURL,
                      self.subtitleSynchronizationIDs[slot] == synchronizationID else {
                    return
                }
                self.applySynchronization(match, to: slot)
                self.subtitleSynchronizationTasks[slot] = nil
            } catch is CancellationError {
                guard self.subtitleSynchronizationIDs[slot] == synchronizationID else { return }
                self.updateTrack(slot) { $0.synchronizationState = .idle }
                self.subtitleSynchronizationTasks[slot] = nil
                self.schedulePhraseAlignmentRebuild()
            } catch {
                guard self.subtitleSynchronizationIDs[slot] == synchronizationID else { return }
                self.updateTrack(slot) {
                    $0.synchronizationState = .failed(error.localizedDescription)
                }
                self.subtitleSynchronizationTasks[slot] = nil
                self.showHUD("\(slot.shortTitle): не удалось проверить синхронизацию")
                self.schedulePhraseAlignmentRebuild()
            }
        }
    }

    func resetSubtitleSynchronization(for slot: SubtitleSlot) {
        cancelSubtitleSynchronization(for: slot)
        updateTrack(slot) { track in
            track.offset = 0
            track.timingTransform = .identity
            track.synchronizationState = .idle
        }
        persistSubtitleBinding(for: slot)
        schedulePhraseAlignmentRebuild()
        showHUD("\(slot.shortTitle): вся синхронизация сброшена")
    }

    func clearTrack(_ slot: SubtitleSlot) {
        cancelSubtitleSynchronization(for: slot)
        subtitleLoadIDs[slot] = nil
        subtitleMutationIDs[slot] = UUID()
        if let videoURL {
            subtitleBindingStore.removeBinding(for: videoURL, slot: slot)
        }
        updateTrack(slot) { track in
            track = SubtitleTrack(slot: slot)
        }
        schedulePhraseAlignmentRebuild()
        showHUD("\(slot.shortTitle) удалены")
    }

    func setTrackEnabled(_ slot: SubtitleSlot, enabled: Bool) {
        updateTrack(slot) { $0.isEnabled = enabled }
        persistSubtitleBinding(for: slot)
        showHUD("\(slot.shortTitle): \(enabled ? "включены" : "выключены")")
    }

    func toggleTrack(_ slot: SubtitleSlot) {
        let track = track(for: slot)
        guard track.isLoaded else {
            chooseSubtitle(for: slot)
            return
        }
        setTrackEnabled(slot, enabled: !track.isEnabled)
    }

    func adjustOffset(for slot: SubtitleSlot, by amount: TimeInterval) {
        cancelAnalyzingSynchronizationForManualAdjustment(for: slot)
        updateTrack(slot) { track in
            track.offset = min(max((track.offset + amount).rounded(toPlaces: 2), -120), 120)
        }
        let value = track(for: slot).offset
        persistSubtitleBinding(for: slot)
        schedulePhraseAlignmentRebuild()
        showHUD("\(slot.shortTitle): \(Self.formatOffset(value))")
    }

    func setOffset(for slot: SubtitleSlot, to value: TimeInterval) {
        cancelAnalyzingSynchronizationForManualAdjustment(for: slot)
        updateTrack(slot) { $0.offset = min(max(value, -120), 120) }
        persistSubtitleBinding(for: slot)
        schedulePhraseAlignmentRebuild()
    }

    func resetOffset(for slot: SubtitleSlot) {
        setOffset(for: slot, to: 0)
        showHUD("\(slot.shortTitle): синхронизация сброшена")
    }

    func togglePlayback() {
        guard player.currentItem != nil else {
            chooseVideo()
            return
        }
        if player.timeControlStatus == .playing {
            player.pause()
            showHUD("Пауза")
        } else {
            if duration > 0, currentTime >= duration - 0.15 {
                player.seek(to: .zero)
            }
            player.playImmediately(atRate: selectedPlaybackRate)
            showHUD("Воспроизведение")
        }
    }

    func seek(by delta: TimeInterval) {
        guard player.currentItem != nil else { return }
        let target = min(max(currentTime + delta, 0), max(duration, 0))
        seek(to: target)
        showHUD(delta >= 0 ? "+\(Int(abs(delta))) секунд" : "−\(Int(abs(delta))) секунд")
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setPlaybackRate(_ value: Double) {
        let rate = Float(min(max(value, 0.25), 3))
        selectedPlaybackRate = rate
        playbackRate = rate
        if player.timeControlStatus == .playing {
            player.rate = rate
        }
        showHUD("Скорость \(Self.formatRate(rate))")
    }

    func adjustPlaybackRate(up: Bool) {
        let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
        let current = selectedPlaybackRate
        let next: Float
        if up {
            next = rates.first(where: { $0 > current + 0.01 }) ?? rates.last!
        } else {
            next = rates.last(where: { $0 < current - 0.01 }) ?? rates.first!
        }
        setPlaybackRate(Double(next))
    }

    func toggleMute() {
        player.isMuted.toggle()
        showHUD(player.isMuted ? "Звук выключен" : "Звук включен")
    }

    func adjustVolume(by amount: Float) {
        player.volume = min(max(player.volume + amount, 0), 1)
        if player.volume > 0 { player.isMuted = false }
        if preferences.rememberVolume {
            preferences.lastVolume = Double(player.volume)
        }
        showHUD("Громкость \(Int(player.volume * 100))%")
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        let expectedVideoSessionID = videoSessionID
        let expectedSubtitleMutationIDs = Dictionary(
            uniqueKeysWithValues: SubtitleSlot.allCases.compactMap { slot in
                subtitleMutationIDs[slot].map { (slot, $0) }
            }
        )
        let selectedProviders = Array(matching.prefix(3))
        let group = DispatchGroup()
        let collector = DroppedURLCollector(count: selectedProviders.count)

        for (index, provider) in selectedProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsData = item as? NSData {
                    url = URL(dataRepresentation: nsData as Data, relativeTo: nil)
                } else if let loadedURL = item as? URL {
                    url = loadedURL
                } else {
                    url = nil
                }
                guard self != nil, let url else { return }
                collector.set(url, at: index)
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let urls = collector.values
            Task { @MainActor in
                self.handleDroppedURLs(
                    urls,
                    expectedVideoSessionID: expectedVideoSessionID,
                    expectedSubtitleMutationIDs: expectedSubtitleMutationIDs
                )
            }
        }
        return true
    }

    func dismissError() {
        if case .failed = loadingState {
            invalidatePhraseAlignment(state: .waitingForTracks)
            videoSessionID = UUID()
            restoredVideoSessionID = nil
            for slot in SubtitleSlot.allCases {
                cancelSubtitleSynchronization(for: slot)
                subtitleLoadIDs[slot] = nil
                subtitleMutationIDs[slot] = UUID()
                updateTrack(slot) { $0 = SubtitleTrack(slot: slot) }
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
            itemStatusObservation = nil
            activeSecurityScopedVideoURL?.stopAccessingSecurityScopedResource()
            activeSecurityScopedVideoURL = nil
            videoURL = nil
            videoName = nil
            currentTime = 0
            duration = 0
            loadingState = .empty
        }
    }

    private func installObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let controller = self else { return }
            Task { @MainActor in controller.handleTimeUpdate(time) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let controller = self else { return }
            Task { @MainActor in
                controller.isPlaying = false
                controller.showHUD("Конец видео")
                controller.persistCurrentPosition(force: true)
            }
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let controller = self else { return }
            Task { @MainActor in controller.persistCurrentPosition(force: true) }
        }
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch item.status {
        case .unknown:
            break
        case .readyToPlay:
            loadingState = .ready
            duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
            let resumeTime = preferences.resumePlayback ? storedPosition(for: videoURL) : 0
            if resumeTime > 1, resumeTime < max(duration - 5, 1) {
                seek(to: resumeTime)
                currentTime = resumeTime
                showHUD("Продолжено с \(Self.formatTime(resumeTime))")
            }
            selectedPlaybackRate = Float(preferences.defaultPlaybackRate)
            playbackRate = selectedPlaybackRate
            if preferences.autoPlay {
                player.playImmediately(atRate: selectedPlaybackRate)
            }
            restorePersistedSubtitlesForCurrentVideo()
            if preferences.automaticallySynchronizeSubtitles {
                for slot in SubtitleSlot.allCases {
                    let subtitle = track(for: slot)
                    if subtitle.isLoaded,
                       subtitle.timingTransform == .identity,
                       subtitle.synchronizationState != .analyzing {
                        synchronizeSubtitle(for: slot)
                    }
                }
            }
            schedulePhraseAlignmentRebuild()
        case .failed:
            loadingState = .failed(item.error?.localizedDescription ?? "Не удалось открыть видео")
        @unknown default:
            loadingState = .failed("Неизвестная ошибка AVPlayer")
        }
    }

    private func handleTimeUpdate(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite { currentTime = max(0, seconds) }
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        isPlaying = player.timeControlStatus == .playing
        if player.rate > 0, abs(player.rate - playbackRate) > 0.01 {
            playbackRate = player.rate
            selectedPlaybackRate = player.rate
        }
        if preferences.rememberVolume, abs(Double(player.volume) - preferences.lastVolume) > 0.01 {
            preferences.lastVolume = Double(player.volume)
        }
        persistCurrentPosition(force: false)
    }

    private func handleDroppedURLs(
        _ urls: [URL],
        expectedVideoSessionID: UUID,
        expectedSubtitleMutationIDs: [SubtitleSlot: UUID]
    ) {
        guard videoSessionID == expectedVideoSessionID else { return }
        let subtitleURLs = urls.filter(Self.isSubtitleURL)
        let includesVideo = urls.contains(where: Self.isVideoURL)
        if let videoURL = urls.first(where: Self.isVideoURL) {
            openVideo(videoURL)
        }
        let assignmentSessionID = videoSessionID
        for subtitleURL in subtitleURLs.prefix(2) {
            let slot = firstAvailableSubtitleSlot()
            loadSubtitle(
                subtitleURL,
                into: slot,
                expectedVideoSessionID: assignmentSessionID,
                expectedSubtitleMutationID: includesVideo
                    ? nil
                    : expectedSubtitleMutationIDs[slot]
            )
        }
    }

    private func firstAvailableSubtitleSlot() -> SubtitleSlot {
        if primaryTrack.fileURL == nil { return .primary }
        if secondaryTrack.fileURL == nil { return .secondary }
        return .secondary
    }

    private func updateTrack(_ slot: SubtitleSlot, change: (inout SubtitleTrack) -> Void) {
        switch slot {
        case .primary: change(&primaryTrack)
        case .secondary: change(&secondaryTrack)
        }
    }

    private func cancelSubtitleSynchronization(for slot: SubtitleSlot) {
        subtitleSynchronizationIDs[slot] = nil
        subtitleSynchronizationTasks[slot]?.cancel()
        subtitleSynchronizationTasks[slot] = nil
    }

    private func cancelAnalyzingSynchronizationForManualAdjustment(for slot: SubtitleSlot) {
        guard case .analyzing = track(for: slot).synchronizationState else { return }
        cancelSubtitleSynchronization(for: slot)
        updateTrack(slot) { $0.synchronizationState = .idle }
    }

    private func makeSubtitleSearchVideo(for url: URL) async -> SubtitleSearchVideo {
        var frameRate: Double?
        if let asset = player.currentItem?.asset,
           let tracks = try? await asset.loadTracks(withMediaType: .video),
           let videoTrack = tracks.first,
           let nominalFrameRate = try? await videoTrack.load(.nominalFrameRate),
           nominalFrameRate > 0 {
            frameRate = Double(nominalFrameRate)
        }

        return SubtitleSearchVideo(
            url: url,
            duration: duration,
            frameRate: frameRate
        )
    }

    private func applySynchronization(_ match: SubtitleSearchMatch, to slot: SubtitleSlot) {
        guard let transform = match.timingTransform else {
            let message: String
            switch match.verdict {
            case .differentEdit:
                message = "Похоже, это другая версия фильма. Попробуйте другой файл."
            default:
                message = "Недостаточно совпадений речи и реплик для надёжной подгонки."
            }
            updateTrack(slot) { $0.synchronizationState = .uncertain(message) }
            showHUD("\(slot.shortTitle): автокоррекция не применена")
            schedulePhraseAlignmentRebuild()
            return
        }

        guard match.confidence >= 0.68,
              (match.audioMatchScore ?? 0) >= 0.32 else {
            let percentage = Int((match.confidence * 100).rounded())
            updateTrack(slot) {
                $0.synchronizationState = .uncertain(
                    "Совпадение недостаточно уверенное (\(percentage)%); коррекция не применена."
                )
            }
            showHUD("\(slot.shortTitle): автокоррекция требует проверки")
            schedulePhraseAlignmentRebuild()
            return
        }

        updateTrack(slot) { track in
            track.offset = 0
            track.timingTransform = transform
            track.synchronizationState = .synchronized(confidence: match.confidence)
        }
        persistSubtitleBinding(for: slot)
        schedulePhraseAlignmentRebuild()

        let correction = Self.formatAutomaticCorrection(transform)
        showHUD("\(slot.shortTitle): \(correction)")
    }

    private func restorePersistedSubtitlesForCurrentVideo() {
        let sessionID = videoSessionID
        guard restoredVideoSessionID != sessionID,
              let videoURL else {
            return
        }
        restoredVideoSessionID = sessionID

        for slot in SubtitleSlot.allCases {
            guard subtitleMutationIDs[slot] == subtitleRestoreTokens[slot],
                  let binding = subtitleBindingStore.binding(for: videoURL, slot: slot) else {
                continue
            }
            let movieFolderName = OpenSubtitlesCache.movieFolderName(for: videoURL)
            let nestedURL = try? OpenSubtitlesCache.persistentArtifactURL(
                for: binding.fileID,
                movieFolderName: movieFolderName
            )
            let flatURL = try? OpenSubtitlesCache.persistentArtifactURL(
                for: binding.fileID
            )
            guard binding.fileID > 0,
                  let fileURL = [nestedURL, flatURL]
                    .compactMap({ $0 })
                    .first(where: {
                        OpenSubtitlesCache.fileID(forPersistentArtifactURL: $0)
                            == binding.fileID
                    }),
                  OpenSubtitlesCache.fileID(forPersistentArtifactURL: fileURL)
                    == binding.fileID else {
                subtitleBindingStore.removeBinding(for: videoURL, slot: slot)
                showHUD("\(slot.shortTitle): сохранённый файл больше недоступен")
                continue
            }

            let confidence: Double?
            if let value = binding.synchronizationConfidence, value.isFinite {
                confidence = min(max(value, 0), 1)
            } else {
                confidence = nil
            }
            beginSubtitleLoad(
                fileURL,
                into: slot,
                displayName: binding.displayName,
                languageCode: binding.languageCode,
                timingTransform: SubtitleTimingTransform(
                    offset: binding.timingOffset,
                    rate: binding.timingRate
                ),
                synchronizationConfidence: confidence,
                manualOffset: binding.manualOffset,
                isEnabled: binding.isEnabled,
                isRestoringBinding: true
            )
        }
    }

    private func persistSubtitleBinding(for slot: SubtitleSlot) {
        guard let videoURL else { return }
        let subtitle = track(for: slot)
        guard subtitle.isLoaded,
              let fileURL = subtitle.fileURL,
              let location = OpenSubtitlesCache.persistentArtifactLocation(
                for: fileURL
              ),
              location.movieFolderName == nil
                || location.movieFolderName == OpenSubtitlesCache.movieFolderName(for: videoURL) else {
            return
        }

        let synchronizationConfidence: Double?
        if case .synchronized(let confidence) = subtitle.synchronizationState {
            synchronizationConfidence = confidence
        } else {
            synchronizationConfidence = nil
        }
        subtitleBindingStore.setBinding(
            PersistedSubtitleBinding(
                fileID: location.fileID,
                displayName: subtitle.fileName,
                languageCode: subtitle.languageCode,
                isEnabled: subtitle.isEnabled,
                manualOffset: subtitle.offset,
                timingOffset: subtitle.timingTransform.offset,
                timingRate: subtitle.timingTransform.rate,
                synchronizationConfidence: synchronizationConfidence
            ),
            for: videoURL,
            slot: slot
        )
    }

    private func persistCurrentPosition(force: Bool) {
        guard preferences.resumePlayback,
              let videoURL,
              currentTime.isFinite,
              currentTime > 0 else { return }
        guard force || abs(currentTime - lastPersistedPosition) >= 5 else { return }

        var positions = UserDefaults.standard.dictionary(forKey: "videoPositions") as? [String: Double] ?? [:]
        positions[videoURL.path] = currentTime
        if positions.count > 80 {
            positions = Dictionary(uniqueKeysWithValues: positions
                .sorted { $0.value > $1.value }
                .prefix(80)
                .map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(positions, forKey: "videoPositions")
        lastPersistedPosition = currentTime
    }

    private func storedPosition(for url: URL?) -> TimeInterval {
        guard let url,
              let positions = UserDefaults.standard.dictionary(forKey: "videoPositions") as? [String: Double] else { return 0 }
        return positions[url.path] ?? 0
    }

    private func showHUD(_ message: String) {
        hudTask?.cancel()
        hudMessage = message
        hudTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_150_000_000)
            guard !Task.isCancelled else { return }
            self?.hudMessage = nil
        }
    }

    nonisolated static func inferredSubtitleLanguage(
        from cues: [SubtitleCue]
    ) -> String? {
        let joined = cues.prefix(120).map(\.text).joined(separator: " ")
        let sample = String(joined.prefix(12_000))
        guard sample.contains(where: { $0.isLetter }) else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue.lowercased()
    }

    static func isSubtitleURL(_ url: URL) -> Bool {
        ["srt", "vtt"].contains(url.pathExtension.lowercased())
    }

    static func isVideoURL(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "mpg", "mpeg", "ts", "mts", "m2ts"].contains(url.pathExtension.lowercased())
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let value = Int(seconds.rounded(.down))
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let remainder = value % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    static func formatOffset(_ value: TimeInterval) -> String {
        if abs(value) < 0.005 { return "0,0 с" }
        return String(format: "%+.1f с", value).replacingOccurrences(of: ".", with: ",")
    }

    static func formatAutomaticCorrection(_ transform: SubtitleTimingTransform) -> String {
        let startShift = transform.videoTime(forSubtitleTime: 0)
        let driftPerHour = transform.videoTime(forSubtitleTime: 3_600)
            - transform.videoTime(forSubtitleTime: 0)
            - 3_600

        var parts: [String] = []
        if abs(startShift) >= 0.05 {
            parts.append("сдвиг \(formatOffset(startShift))")
        }
        if abs(driftPerHour) >= 0.05 {
            parts.append("дрейф \(formatOffset(driftPerHour))/ч")
        }
        return parts.isEmpty ? "тайминги уже совпадают" : parts.joined(separator: " · ")
    }

    static func formatRate(_ value: Float) -> String {
        let text = String(format: value.rounded() == value ? "%.0f×" : "%.2g×", value)
        return text.replacingOccurrences(of: ".", with: ",")
    }
}

private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func set(_ url: URL, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.indices.contains(index) else { return }
        storage[index] = url
    }

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage.compactMap { $0 }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
