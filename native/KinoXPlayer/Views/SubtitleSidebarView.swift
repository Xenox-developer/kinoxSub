import SwiftUI

struct SubtitleSidebarView: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var preferences: AppPreferences
    @State private var isSubtitleFinderPresented = false
    @State private var subtitleFinderVideoSessionID: UUID?
    @State private var subtitleFinderAssignmentContext = SubtitleFinderAssignmentContext()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Двойные субтитры")
                        .font(.headline)
                    Text("SRT и WebVTT")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        controller.isSidebarVisible = false
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .buttonStyle(.borderless)
                .help("Скрыть панель")
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    SubtitleTrackCard(slot: .primary, controller: controller)
                    SubtitleTrackCard(slot: .secondary, controller: controller)

                    phraseLinkingSection
                    subtitleFinderSection
                    playbackSection
                    hintsSection
                }
                .padding(14)
            }
        }
        .frame(width: 328)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $isSubtitleFinderPresented, onDismiss: {
            subtitleFinderVideoSessionID = nil
            subtitleFinderAssignmentContext.reset()
        }) {
            let expectedVideoSessionID = subtitleFinderVideoSessionID
                ?? controller.currentVideoSessionID
            SubtitleFinderSheet(
                videoName: controller.videoName,
                initialFolderURL: controller.videoURL?.deletingLastPathComponent(),
                movieFolderURL: controller.subtitleFolderURL,
                search: { folderURL in
                    let matches = try await controller.searchSubtitleCandidates(
                        in: folderURL,
                        expectedVideoSessionID: expectedVideoSessionID
                    )
                    return matches.map(makeFinderCandidate)
                },
                online: makeOnlineFinderConfiguration(
                    expectedVideoSessionID: expectedVideoSessionID
                ),
                onAssign: { candidate, destination in
                    let slot: SubtitleSlot = destination == .primary ? .primary : .secondary
                    let fileID = OpenSubtitlesCache.fileID(
                        forPersistentArtifactURL: candidate.fileURL
                    )
                    let expectedMutationID = fileID.flatMap {
                        subtitleFinderAssignmentContext.take(fileID: $0)?[slot]
                    }
                    controller.loadSubtitle(
                        candidate.fileURL,
                        into: slot,
                        displayName: candidate.displayName,
                        languageCode: candidate.languageCode,
                        timingTransform: candidate.timingTransform ?? .identity,
                        synchronizationConfidence: candidate.timingTransform == nil
                            ? nil
                            : candidate.confidence,
                        expectedVideoSessionID: expectedVideoSessionID,
                        expectedSubtitleMutationID: expectedMutationID
                    )
                }
            )
        }
    }

    private var phraseLinkingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Связь S1 ↔ S2", systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle(
                    "Связывать фразы",
                    isOn: $preferences.phraseLinkingEnabled
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!controller.phraseAlignmentModels.isReady)
                .accessibilityLabel("Связывать эквивалентные фразы S1 и S2")
            }

            phraseLinkingStatus
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    @ViewBuilder
    private var phraseLinkingStatus: some View {
        switch controller.phraseModelState {
        case .notInstalled:
            Text("Модель устанавливается один раз и затем работает без интернета.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Установить модель · ~245 МБ") {
                controller.installPhraseAlignmentModel()
            }
            .buttonStyle(.borderedProminent)

        case .downloading(let progress):
            let normalized = min(max(progress.isFinite ? progress : 0, 0), 1)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Загружаю модель…")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(Int((normalized * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: normalized, total: 1)
                    .accessibilityLabel("Загрузка модели связывания фраз")
                    .accessibilityValue("\(Int((normalized * 100).rounded())) процентов")
                Button("Отменить") {
                    controller.cancelPhraseAlignmentModelInstallation()
                }
            }

        case .compiling:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Подготавливаю модель для этого Mac…")
                    .font(.caption)
                Spacer()
                Button("Отменить") {
                    controller.cancelPhraseAlignmentModelInstallation()
                }
            }

        case .failed(let message):
            Label("Модель не установлена", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Повторить") {
                controller.installPhraseAlignmentModel()
            }

        case .ready:
            phraseAlignmentResultStatus
        }
    }

    @ViewBuilder
    private var phraseAlignmentResultStatus: some View {
        if !preferences.phraseLinkingEnabled {
            Text("Связывание выключено")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch controller.phraseAlignmentState {
            case .idle:
                Text("Готово к сопоставлению")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .waitingForTracks:
                Label("Загрузите обе дорожки", systemImage: "text.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .waitingForSynchronization:
                Label("Ожидание синхронизации", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .analyzing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Сравниваю смысл фраз…")
                        .font(.caption.weight(.medium))
                }
            case .aligned(let summary):
                Label(
                    "Связано \(summary.coveragePercent)% фраз",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)

                let unmatched = summary.primaryFragmentCount
                    + summary.secondaryFragmentCount
                    - summary.alignedPrimaryFragmentCount
                    - summary.alignedSecondaryFragmentCount
                if unmatched > 0 {
                    Label(
                        "\(unmatched) непарных фрагментов будут показаны отдельно",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Button("Пересопоставить") {
                    controller.rebuildPhraseAlignment()
                }
                .controlSize(.small)

            case .failed(let message):
                Label("Не удалось связать фразы", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Повторить") {
                    controller.rebuildPhraseAlignment()
                }
                .controlSize(.small)
            }
        }
    }

    private var subtitleFinderSection: some View {
        VStack(spacing: 8) {
            Button {
                subtitleFinderAssignmentContext.reset()
                subtitleFinderVideoSessionID = controller.currentVideoSessionID
                _ = controller.ensureSubtitleFolderForCurrentVideo()
                isSubtitleFinderPresented = true
            } label: {
                Label("Найти подходящие субтитры…", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!controller.isVideoReady)
            .help(controller.isVideoReady
                ? "Найти субтитры в интернете или проверить локальные файлы"
                : controller.hasVideo
                    ? "Подождите, пока видео откроется"
                    : "Сначала откройте видео")
            .accessibilityHint("Открывает поиск OpenSubtitles и локальную проверку файлов")

            Button {
                controller.openSubtitleLibrary()
            } label: {
                Label(
                    controller.videoURL == nil ? "Открыть медиатеку загрузок" : "Открыть папку фильма",
                    systemImage: "folder"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help(controller.videoURL == nil
                ? "Открыть постоянную папку интернет-субтитров в Finder"
                : "Открыть папку субтитров текущего фильма в Finder")
        }
    }

    private func makeOnlineFinderConfiguration(
        expectedVideoSessionID: UUID
    ) -> SubtitleFinderOnlineConfiguration? {
        guard let service = KinoXOpenSubtitlesEnvironment.service,
              let keyManagementURL = URL(string: "https://www.opensubtitles.com/en/consumers") else {
            return nil
        }

        return SubtitleFinderOnlineConfiguration(
            initialAPIKeyState: service.hasAPIKey() ? .ready : .missing,
            initialAccountState: service.hasStoredSession() ? .signedIn(nil) : .signedOut,
            keyManagementURL: keyManagementURL,
            initialLanguages: ["ru", "de"],
            validateAndStoreKey: { key in
                do {
                    try await service.validateAndStoreAPIKey(key)
                } catch {
                    throw Self.finderError(from: error, operation: .configuration)
                }
            },
            removeKey: {
                do {
                    try service.removeAPIKey()
                } catch {
                    throw Self.finderError(from: error, operation: .configuration)
                }
            },
            search: { request in
                guard expectedVideoSessionID == controller.currentVideoSessionID,
                      let videoURL = controller.videoURL else {
                    throw SubtitleFinderOnlineError.provider("Сначала откройте видео.")
                }

                do {
                    let candidates = try await service.search(
                        videoURL: videoURL,
                        query: request.query,
                        languages: request.languages
                    )
                    guard expectedVideoSessionID == controller.currentVideoSessionID else {
                        throw CancellationError()
                    }
                    return candidates.map(Self.makeRemoteFinderCandidate)
                } catch {
                    throw Self.finderError(from: error, operation: .search)
                }
            },
            materialize: { remote in
                guard expectedVideoSessionID == controller.currentVideoSessionID else {
                    throw CancellationError()
                }
                guard let materializedVideoURL = controller.videoURL else {
                    throw SubtitleFinderOnlineError.provider("Сначала откройте видео.")
                }
                guard let fileID = Int(remote.remoteIdentifier) else {
                    throw SubtitleFinderOnlineError.download("OpenSubtitles вернул неверный идентификатор файла.")
                }
                subtitleFinderAssignmentContext.capture(
                    fileID: fileID,
                    mutationIDs: Dictionary(
                        uniqueKeysWithValues: SubtitleSlot.allCases.compactMap { slot in
                            controller.currentSubtitleMutationID(for: slot).map { (slot, $0) }
                        }
                    )
                )

                do {
                    let artifact = try await service.materialize(
                        fileID: fileID,
                        suggestedFileName: remote.displayName,
                        videoURL: materializedVideoURL
                    )
                    guard expectedVideoSessionID == controller.currentVideoSessionID,
                          controller.videoURL == materializedVideoURL else {
                        throw CancellationError()
                    }
                    return SubtitleFinderCandidate(
                        fileURL: artifact.fileURL,
                        displayName: remote.displayName,
                        languageCode: remote.languageCode,
                        languageName: remote.languageName,
                        formatName: "SRT",
                        releaseName: "\(artifact.cueCount) реплик · OpenSubtitles.com",
                        assessment: remote.isHashMatch ? .suitable : .unverified,
                        timingTransform: .identity,
                        confidence: remote.isHashMatch ? 1 : 0.5
                    )
                } catch {
                    throw Self.finderError(from: error, operation: .download)
                }
            },
            hasStoredSession: {
                service.hasStoredSession()
            },
            login: { username, password in
                do {
                    try await service.login(username: username, password: password)
                } catch {
                    throw Self.finderError(from: error, operation: .login)
                }
            },
            logout: {
                do {
                    try await service.logout()
                } catch {
                    throw Self.finderError(from: error, operation: .login)
                }
            }
        )
    }

    private nonisolated static func makeRemoteFinderCandidate(
        _ candidate: OpenSubtitlesCandidate
    ) -> SubtitleFinderRemoteCandidate {
        let languageName = onlineLanguageNames[candidate.language.lowercased()]
            ?? candidate.language.uppercased()
        let displayName = candidate.fileName
            ?? candidate.releaseName
            ?? candidate.featureTitle
            ?? "Субтитры #\(candidate.fileID)"

        var releaseParts: [String] = []
        if let releaseName = candidate.releaseName, releaseName != displayName {
            releaseParts.append(releaseName)
        }
        if let title = candidate.featureTitle, title != displayName {
            let titledYear = candidate.featureYear.map { "\(title) (\($0))" } ?? title
            releaseParts.append(titledYear)
        }
        if candidate.hearingImpaired { releaseParts.append("для слабослышащих") }
        if candidate.forced { releaseParts.append("только иностранная речь") }

        return SubtitleFinderRemoteCandidate(
            remoteIdentifier: String(candidate.fileID),
            displayName: displayName,
            languageCode: candidate.language,
            languageName: languageName,
            releaseName: releaseParts.isEmpty ? nil : releaseParts.joined(separator: " · "),
            formatName: "SRT",
            framesPerSecond: candidate.framesPerSecond,
            rating: candidate.rating,
            downloadCount: candidate.downloadCount,
            isHashMatch: candidate.matchKind == .exactHash
        )
    }

    private enum OnlineOperation: Equatable {
        case configuration
        case search
        case login
        case download
    }

    private static func finderError(
        from error: Error,
        operation: OnlineOperation
    ) -> Error {
        if error is CancellationError { return CancellationError() }
        guard let error = error as? OpenSubtitlesError else {
            return operation == .download
                ? SubtitleFinderOnlineError.download("Не удалось загрузить субтитры.")
                : SubtitleFinderOnlineError.provider("OpenSubtitles временно недоступен.")
        }

        switch error {
        case .missingAPIKey, .invalidAPIKey, .forbidden:
            return SubtitleFinderOnlineError.invalidAPIKey
        case .loginRequired, .unauthorized:
            if operation == .login {
                return SubtitleFinderOnlineError.provider(
                    "Имя пользователя или пароль OpenSubtitles не подошли. Проверьте их и попробуйте снова."
                )
            }
            return operation == .configuration
                ? SubtitleFinderOnlineError.invalidAPIKey
                : SubtitleFinderOnlineError.loginRequired
        case .rateLimited(let retryAfter):
            let message = retryAfter.map {
                "Сервис ограничил число запросов. Повторите через \(Int($0.rounded(.up))) сек."
            }
            return SubtitleFinderOnlineError.rateLimited(message)
        case .offline:
            return SubtitleFinderOnlineError.offline
        case .cancelled:
            return CancellationError()
        default:
            let message = error.localizedDescription
            return operation == .download
                ? SubtitleFinderOnlineError.download(message)
                : SubtitleFinderOnlineError.provider(message)
        }
    }

    private static let onlineLanguageNames: [String: String] = [
        "ru": "Русский",
        "de": "Немецкий",
        "en": "Английский",
        "es": "Испанский",
        "fr": "Французский",
        "it": "Итальянский",
        "uk": "Украинский",
        "pl": "Польский",
        "pt": "Португальский",
        "pt-br": "Португальский (Бразилия)",
        "pt-pt": "Португальский (Португалия)"
    ]

    private nonisolated func makeFinderCandidate(_ match: SubtitleSearchMatch) -> SubtitleFinderCandidate {
        let assessment: SubtitleFinderAssessment
        switch match.verdict {
        case .suitable:
            assessment = .suitable
        case .timeOffset(let seconds):
            assessment = .timeOffset(seconds: seconds)
        case .frameRate(let subtitleFPS, let videoFPS):
            if let subtitleFPS, let videoFPS {
                assessment = .frameRate(subtitleFPS: subtitleFPS, videoFPS: videoFPS)
            } else {
                assessment = .unverified
            }
        case .differentEdit:
            assessment = .differentEdit
        case .unverified:
            assessment = .unverified
        }

        let candidate = match.candidate
        // Local subtitles are classified from their actual text. A filename tag
        // is only a fallback because release names are often copied or wrong.
        let languageCode = PlayerController.inferredSubtitleLanguage(
            from: candidate.cues
        ) ?? inferredLanguageCode(for: candidate.url)
        return SubtitleFinderCandidate(
            fileURL: candidate.url,
            languageCode: languageCode,
            languageName: languageCode.flatMap { Self.onlineLanguageNames[$0] },
            formatName: candidate.format.rawValue.uppercased(),
            releaseName: "\(candidate.cueCount) реплик · \(candidate.encodingName)",
            assessment: assessment,
            timingTransform: match.timingTransform,
            confidence: match.confidence
        )
    }

    private nonisolated func inferredLanguageName(for url: URL) -> String? {
        guard let code = inferredLanguageCode(for: url) else { return nil }
        return Self.onlineLanguageNames[code]
    }

    private nonisolated func inferredLanguageCode(for url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let tokens = Set(name.split { !$0.isLetter }.map(String.init))
        if !tokens.isDisjoint(with: ["ru", "rus", "russian", "рус"]) { return "ru" }
        if !tokens.isDisjoint(with: ["de", "deu", "ger", "german", "deutsch"]) { return "de" }
        if !tokens.isDisjoint(with: ["en", "eng", "english"]) { return "en" }
        if !tokens.isDisjoint(with: ["es", "spa", "spanish"]) { return "es" }
        if !tokens.isDisjoint(with: ["fr", "fra", "fre", "french"]) { return "fr" }
        if !tokens.isDisjoint(with: ["it", "ita", "italian"]) { return "it" }
        return nil
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Воспроизведение", systemImage: "speedometer")
                .font(.subheadline.weight(.semibold))

            HStack {
                Text("Скорость")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Скорость", selection: Binding(
                    get: { Double(controller.playbackRate) },
                    set: { controller.setPlaybackRate($0) }
                )) {
                    Text("0,5×").tag(0.5)
                    Text("0,75×").tag(0.75)
                    Text("1×").tag(1.0)
                    Text("1,25×").tag(1.25)
                    Text("1,5×").tag(1.5)
                    Text("1,75×").tag(1.75)
                    Text("2×").tag(2.0)
                }
                .labelsHidden()
                .frame(width: 92)
            }

            Toggle("Заполнять окно видео", isOn: $preferences.fillVideo)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var hintsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Быстрые клавиши", systemImage: "keyboard")
                .font(.subheadline.weight(.semibold))
            shortcut("Пауза / продолжить", "Пробел")
            shortcut("Перемотка", "←  →")
            shortcut("Громкость", "↑  ↓")
            shortcut("Полный экран", "⌃⌘F")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func shortcut(_ label: String, _ keys: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(keys)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

@MainActor
private final class SubtitleFinderAssignmentContext {
    private var mutationIDsByFileID: [Int: [SubtitleSlot: UUID]] = [:]

    func capture(fileID: Int, mutationIDs: [SubtitleSlot: UUID]) {
        mutationIDsByFileID[fileID] = mutationIDs
    }

    func take(fileID: Int) -> [SubtitleSlot: UUID]? {
        mutationIDsByFileID.removeValue(forKey: fileID)
    }

    func reset() {
        mutationIDsByFileID.removeAll()
    }
}

private enum KinoXOpenSubtitlesEnvironment {
    static let service: OpenSubtitlesService? = try? OpenSubtitlesService()
}

private struct SubtitleTrackCard: View {
    let slot: SubtitleSlot
    @ObservedObject var controller: PlayerController

    private var track: SubtitleTrack { controller.track(for: slot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(slot.shortTitle)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 27)
                    .background(slot == .primary ? Color.accentColor : Color.orange, in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(slot == .primary ? "Основная дорожка" : "Вторая дорожка")
                        .font(.subheadline.weight(.semibold))
                    Text(track.fileName ?? "Файл не выбран")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                Toggle("\(slot.shortTitle) включены", isOn: Binding(
                    get: { track.isEnabled },
                    set: { controller.setTrackEnabled(slot, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!track.isLoaded)
            }

            if track.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Читаю субтитры…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = track.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if track.isLoaded {
                Text("\(track.cues.count) реплик · \(track.encodingName ?? "кодировка авто")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    controller.chooseSubtitle(for: slot)
                } label: {
                    Label(track.isLoaded ? "Заменить" : "Загрузить", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if track.fileURL != nil {
                    Menu {
                        Button {
                            controller.revealSubtitleFile(for: slot)
                        } label: {
                            Label("Показать в Finder", systemImage: "folder")
                        }

                        Button {
                            controller.saveSubtitleCopy(for: slot)
                        } label: {
                            Label("Сохранить копию…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("Файл", systemImage: "doc")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Показать или сохранить файл \(slot.shortTitle)")
                    .accessibilityLabel("Действия с файлом \(slot.shortTitle)")

                    Button(role: .destructive) {
                        controller.clearTrack(slot)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help("Удалить дорожку")
                    .accessibilityLabel("Удалить \(slot.shortTitle)")
                }
            }

            if track.isLoaded {
                automaticSynchronizationSection
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Синхронизация")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Сбросить всё") {
                        controller.resetSubtitleSynchronization(for: slot)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .disabled(!hasSynchronizationToReset)
                }

                HStack(spacing: 8) {
                    Button {
                        controller.adjustOffset(for: slot, by: -0.5)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Показать на 0,5 с раньше")
                    .accessibilityLabel("\(slot.shortTitle) на 0,5 секунды раньше")

                    Text(PlayerController.formatOffset(track.offset))
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .frame(maxWidth: .infinity)

                    Button {
                        controller.adjustOffset(for: slot, by: 0.5)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Показать на 0,5 с позже")
                    .accessibilityLabel("\(slot.shortTitle) на 0,5 секунды позже")
                }
                .buttonStyle(.bordered)
                .disabled(!track.isLoaded || isAnalyzingSynchronization)

                Slider(
                    value: Binding(
                        get: { track.offset },
                        set: { controller.setOffset(for: slot, to: $0) }
                    ),
                    in: -120...120,
                    step: 0.1
                ) {
                    Text("Синхронизация \(slot.shortTitle)")
                }
                .labelsHidden()
                .accessibilityValue(PlayerController.formatOffset(track.offset))
                .disabled(!track.isLoaded || isAnalyzingSynchronization)
            }
        }
        .padding(14)
        .background(.background.opacity(0.58), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 1)
        }
    }

    private var isAnalyzingSynchronization: Bool {
        if case .analyzing = track.synchronizationState { return true }
        return false
    }

    private var hasSynchronizationToReset: Bool {
        if abs(track.offset) >= 0.005 || track.timingTransform != .identity {
            return true
        }
        switch track.synchronizationState {
        case .idle:
            return false
        default:
            return true
        }
    }

    private var automaticSynchronizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            synchronizationStatus

            Button {
                controller.synchronizeSubtitle(for: slot)
            } label: {
                HStack(spacing: 7) {
                    if isAnalyzingSynchronization {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "waveform.badge.magnifyingglass")
                    }
                    Text(isAnalyzingSynchronization
                        ? "Подгоняю к речи…"
                        : "Подогнать автоматически")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAnalyzingSynchronization || !controller.hasVideo)
            .accessibilityHint("Сравнивает реплики с речью в фильме и исправляет сдвиг и дрейф")
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var synchronizationStatus: some View {
        switch track.synchronizationState {
        case .idle:
            Label("Автоподгонка ещё не выполнялась", systemImage: "waveform")
                .foregroundStyle(.secondary)
        case .analyzing:
            Label("Сравниваю речь и реплики", systemImage: "waveform")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Выполняется автоматическая синхронизация \(slot.shortTitle)")
        case .synchronized(let confidence):
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    track.hasAutomaticTimingCorrection
                        ? "Подогнано автоматически"
                        : "Тайминги уже совпадают",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                Text(synchronizationDetails(confidence: confidence))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .uncertain(let message):
            Label(message, systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func synchronizationDetails(confidence: Double?) -> String {
        var result = PlayerController.formatAutomaticCorrection(track.timingTransform)
        if let confidence {
            result += " · уверенность \(Int((confidence * 100).rounded()))%"
        }
        return result
    }
}
