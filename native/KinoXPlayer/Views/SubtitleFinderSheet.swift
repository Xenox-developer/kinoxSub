import SwiftUI

@MainActor
struct SubtitleFinderSheet: View {
    typealias AssignmentHandler = (SubtitleFinderCandidate, SubtitleFinderDestination) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SubtitleFinderViewModel
    @State private var subtitleFileActionError: String?
    @FocusState private var isAccountUsernameFocused: Bool
    @AccessibilityFocusState private var isAccountUsernameAccessibilityFocused: Bool

    private let videoName: String?
    private let movieFolderURL: URL?
    private let onAssign: AssignmentHandler

    init(
        videoName: String?,
        initialFolderURL: URL? = nil,
        movieFolderURL: URL? = nil,
        search: @escaping SubtitleFinderViewModel.SearchHandler,
        folderPicker: @escaping SubtitleFinderViewModel.FolderPicker = SubtitleFinderViewModel.pickFolderUsingSystemPanel,
        online: SubtitleFinderOnlineConfiguration? = nil,
        onAssign: @escaping AssignmentHandler
    ) {
        self.videoName = videoName
        self.movieFolderURL = movieFolderURL
        self.onAssign = onAssign
        _model = StateObject(
            wrappedValue: SubtitleFinderViewModel(
                initialFolderURL: initialFolderURL,
                initialOnlineQuery: videoName ?? "",
                search: search,
                folderPicker: folderPicker,
                online: online
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.mode == .local {
                folderBar
                Divider()
                localContent
            } else {
                onlineControls
                Divider()
                onlineContent
            }

            Divider()
            footer
        }
        .frame(width: 780, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.accountState) { state in
            guard case .expired = state else { return }
            DispatchQueue.main.async {
                isAccountUsernameFocused = true
                isAccountUsernameAccessibilityFocused = true
            }
        }
        .alert(
            "Не удалось выполнить действие",
            isPresented: Binding(
                get: { subtitleFileActionError != nil },
                set: { if !$0 { subtitleFileActionError = nil } }
            )
        ) {
            Button("ОК", role: .cancel) {
                subtitleFileActionError = nil
            }
        } message: {
            Text(subtitleFileActionError ?? "Неизвестная ошибка")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Найти подходящие субтитры")
                    .font(.title2.weight(.semibold))

                if let videoName, !videoName.isEmpty {
                    Text("Для «\(videoName)»")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Сравните файлы и выберите лучшие для S1 и S2")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 18)

            Picker("Источник поиска", selection: $model.mode) {
                Text("В интернете").tag(SubtitleFinderMode.online)
                Text("На Mac").tag(SubtitleFinderMode.local)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
            .accessibilityLabel("Источник поиска")
            .disabled(model.isDownloadingOnlineCandidate)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var folderBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.folderURL?.lastPathComponent ?? "Папка не выбрана")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(model.folderURL?.deletingLastPathComponent().path ?? "Выберите папку рядом с видео или папку загрузок")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if model.folderURL != nil, model.phase != .searching {
                Button("Проверить снова") {
                    model.startSearch()
                }
                .disabled(model.isChoosingFolder)
            }

            Button(model.folderURL == nil ? "Выбрать папку…" : "Другая папка…") {
                model.chooseFolder()
            }
            .disabled(model.phase == .searching || model.isChoosingFolder)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private var onlineControls: some View {
        VStack(spacing: 10) {
            apiKeyControls

            if model.apiKeyState == .ready {
                if model.supportsAccountAuthentication {
                    Divider()
                    accountControls
                }

                Divider()
                onlineSearchControls
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var apiKeyControls: some View {
        switch model.apiKeyState {
        case .unavailable:
            HStack(spacing: 9) {
                Image(systemName: "network.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Онлайн-поиск не подключён в этой сборке")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }

        case .missing:
            apiKeyEditor(message: "Для поиска в интернете нужен API-ключ OpenSubtitles.")

        case .invalid(let message):
            apiKeyEditor(message: message)

        case .validating:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Проверяем API-ключ")
                Text("Проверяем и сохраняем API-ключ…")
                    .font(.callout)
                Spacer()
            }

        case .ready:
            if model.isEditingAPIKey {
                apiKeyEditor(message: "Введите новый API-ключ OpenSubtitles.")
            } else {
                HStack(spacing: 10) {
                    Label("API-ключ сохранён", systemImage: "checkmark.shield.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)

                    Spacer()

                    apiKeyLink

                    Button("Сменить ключ…") {
                        model.beginEditingAPIKey()
                    }

                    Button("Удалить") {
                        model.removeAPIKey()
                    }
                    .accessibilityLabel("Удалить API-ключ OpenSubtitles")
                }
            }
        }
    }

    private func apiKeyEditor(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                apiKeyLink
            }

            HStack(spacing: 8) {
                SecureField("API-ключ", text: $model.apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.validateAndStoreAPIKey() }
                    .accessibilityLabel("API-ключ OpenSubtitles")

                if model.apiKeyState == .ready {
                    Button("Отмена") {
                        model.cancelEditingAPIKey()
                    }
                }

                Button("Сохранить") {
                    model.validateAndStoreAPIKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint("Ключ будет проверен и передан защищённому хранилищу приложения")
            }
        }
    }

    @ViewBuilder
    private var apiKeyLink: some View {
        if let keyManagementURL = model.keyManagementURL {
            Link("Получить ключ", destination: keyManagementURL)
                .accessibilityHint("Открывает страницу OpenSubtitles в браузере")
        }
    }

    @ViewBuilder
    private var accountControls: some View {
        switch model.accountState {
        case .signingIn:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Выполняется вход в OpenSubtitles")
                Text("Входим в аккаунт OpenSubtitles…")
                    .font(.caption)
                Spacer()
            }

        case .signingOut:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Выполняется выход из OpenSubtitles")
                Text("Выходим из аккаунта OpenSubtitles…")
                    .font(.caption)
                Spacer()
            }

        case .signedIn(let name):
            if model.isEditingAccount {
                accountEditor(message: "Войдите под другим аккаунтом. Поиск работает и без входа.", showsCancel: true)
            } else {
                HStack(spacing: 9) {
                    Label(
                        name.map { "Выполнен вход: \($0)" } ?? "Выполнен вход в OpenSubtitles",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)

                    Spacer()

                    Button("Другой аккаунт…") {
                        model.beginEditingAccount()
                    }
                    Button("Выйти") {
                        model.logout()
                    }
                }
            }

        case .signedOut:
            if model.isEditingAccount {
                accountEditor(message: "Аккаунт нужен только для загрузки некоторых файлов.", showsCancel: true)
            } else {
                HStack(spacing: 9) {
                    Label("Без входа — поиск доступен", systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Войти для загрузки…") {
                        model.beginEditingAccount()
                    }
                }
            }

        case .expired:
            accountEditor(
                message: "Сеанс истёк или для выбранного файла нужен вход. Результаты поиска сохранены.",
                showsCancel: false
            )
        }
    }

    private func accountEditor(message: String, showsCancel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Имя пользователя", text: $model.accountUsername)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150)
                    .focused($isAccountUsernameFocused)
                    .accessibilityFocused($isAccountUsernameAccessibilityFocused)
                    .accessibilityLabel("Имя пользователя OpenSubtitles")

                SecureField("Пароль", text: $model.accountPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150)
                    .onSubmit { model.login() }
                    .accessibilityLabel("Пароль OpenSubtitles")

                if showsCancel {
                    Button("Отмена") {
                        model.cancelEditingAccount()
                    }
                }

                Button("Войти") {
                    model.login()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.accountUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.accountPassword.isEmpty
                )
            }
        }
    }

    private var onlineSearchControls: some View {
        HStack(spacing: 10) {
            TextField("Название фильма или сериала", text: $model.onlineQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.startOnlineSearch() }
                .accessibilityLabel("Название фильма или сериала")
                .accessibilityHint("Введите запрос для поиска субтитров в интернете")

            languageMenu

            Button("Найти") {
                model.startOnlineSearch()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.onlineQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.onlinePhase == .searching
                    || model.isDownloadingOnlineCandidate
            )
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(model.availableLanguages) { language in
                Toggle(
                    language.displayName,
                    isOn: Binding(
                        get: { model.selectedLanguageCodes.contains(language.code) },
                        set: { model.setLanguage(language.code, selected: $0) }
                    )
                )
            }
        } label: {
            Label(languageSelectionTitle, systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 150)
        .accessibilityLabel("Языки поиска: \(languageSelectionAccessibilityText)")
        .accessibilityHint("Можно выбрать несколько языков")
    }

    private var languageSelectionTitle: String {
        let selected = model.availableLanguages.filter { model.selectedLanguageCodes.contains($0.code) }
        if selected.count == 1 { return selected[0].displayName }
        return "Языки: \(selected.count)"
    }

    private var languageSelectionAccessibilityText: String {
        model.availableLanguages
            .filter { model.selectedLanguageCodes.contains($0.code) }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    @ViewBuilder
    private var onlineContent: some View {
        switch model.apiKeyState {
        case .unavailable:
            onlineStatusPlaceholder(
                symbol: "network.slash",
                title: "Онлайн-поиск пока недоступен",
                message: "Для этой сборки не настроено подключение к OpenSubtitles.com. Локальный поиск доступен на вкладке «На Mac»."
            )

        case .missing, .invalid:
            onlineStatusPlaceholder(
                symbol: "key",
                title: "Сохраните API-ключ",
                message: "Введите ключ выше. Он нужен для запросов к OpenSubtitles.com."
            )

        case .validating:
            onlineStatusPlaceholder(
                symbol: "hourglass",
                title: "Проверяем API-ключ",
                message: "После успешной проверки поиск станет доступен автоматически."
            )

        case .ready:
            onlinePhaseContent
        }
    }

    @ViewBuilder
    private var onlinePhaseContent: some View {
        switch model.onlinePhase {
        case .idle:
            onlineStatusPlaceholder(
                symbol: "magnifyingglass",
                title: "Найдите субтитры в интернете",
                message: "Введите название и выберите языки. OpenSubtitles получит короткий отпечаток видео, но сам фильм и его аудио никуда не загружаются."
            )

        case .searching:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Ищем субтитры в интернете")
                Text("Ищем на OpenSubtitles.com…")
                    .font(.headline)
                Text("Поиск не требует входа в аккаунт")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Отменить") {
                    model.cancelOnlineSearch()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            placeholder(
                symbol: "magnifyingglass",
                title: "Ничего не найдено",
                message: "Попробуйте изменить название или выбрать другие языки.",
                buttonTitle: "Повторить поиск",
                action: model.startOnlineSearch
            )

        case .failed(let message):
            onlineFailureState(message: message)

        case .results, .downloading:
            onlineResults
        }
    }

    private func onlineStatusPlaceholder(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var onlineResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(onlineResultCountText)
                    .font(.headline)
                Spacer()
                Text("Результаты OpenSubtitles.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Результаты предоставлены OpenSubtitles.com")
            }

            List(selection: $model.selectedRemoteCandidateID) {
                ForEach(model.remoteCandidates) { candidate in
                    SubtitleFinderRemoteCandidateRow(
                        candidate: candidate,
                        isMaterialized: model.isMaterialized(candidate),
                        assignedDestinations: model.assignedDestinations(for: candidate)
                    )
                    .tag(candidate.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .disabled(model.isDownloadingOnlineCandidate)

            if let downloadedCandidate = model.selectedMaterializedCandidate {
                HStack(spacing: 10) {
                    Label(
                        "Файл сохранён в папке «\(movieFolderURL?.lastPathComponent ?? "Фильм")»",
                        systemImage: "checkmark.circle.fill"
                    )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)

                    Spacer()

                    Button("Показать в Finder") {
                        revealDownloadedCandidate(downloadedCandidate)
                    }

                    Button("Сохранить копию…") {
                        saveDownloadedCandidate(downloadedCandidate)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Сохранить дополнительную копию в выбранную папку")
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func onlineFailureState(message: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Не получилось выполнить действие")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)
            HStack {
                if !model.remoteCandidates.isEmpty {
                    Button("Вернуться к результатам") {
                        model.dismissOnlineError()
                    }
                }
                Button("Повторить поиск") {
                    model.startOnlineSearch()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var localContent: some View {
        switch model.phase {
        case .needsFolder:
            placeholder(
                symbol: "folder.badge.plus",
                title: "Выберите папку с субтитрами",
                message: "KinoX проверит файлы SRT и WebVTT на вашем Mac. Ничего не отправляется в интернет.",
                buttonTitle: "Выбрать папку…",
                action: model.chooseFolder
            )

        case .readyToSearch:
            placeholder(
                symbol: "magnifyingglass",
                title: "Папка готова к проверке",
                message: "Поиск покажет, какие субтитры подходят, требуют смещения или созданы для другого монтажа.",
                buttonTitle: "Начать поиск",
                action: model.startSearch
            )

        case .searching:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Проверяем субтитры")
                Text("Проверяем субтитры…")
                    .font(.headline)
                Text("Первый анализ аудио обычно занимает 20–40 секунд")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Отменить") {
                    model.cancelSearch()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            placeholder(
                symbol: "doc.text.magnifyingglass",
                title: "Субтитры не найдены",
                message: "В этой папке нет подходящих файлов. Попробуйте выбрать папку с видео или другую папку загрузок.",
                buttonTitle: "Выбрать другую папку…",
                action: model.chooseFolder
            )

        case .failed(let message):
            failureState(message: message)

        case .results:
            results
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(resultCountText)
                    .font(.headline)
                Spacer()
                Text("Лучшие варианты показаны первыми")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List(selection: $model.selectedCandidateID) {
                ForEach(model.candidates) { candidate in
                    SubtitleFinderCandidateRow(
                        candidate: candidate,
                        assignedDestinations: model.assignedDestinations(for: candidate)
                    )
                    .tag(candidate.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            if let selectedCandidate = model.selectedCandidate {
                SubtitleFinderAssessmentDetail(assessment: selectedCandidate.assessment)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var footer: some View {
        if model.mode == .local {
            localFooter
        } else {
            onlineFooter
        }
    }

    private var localFooter: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("S1 — основные · S2 — вторые")
                    .font(.caption.weight(.medium))
                Text(localFooterHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Закрыть") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if !model.candidates.isEmpty {
                Button(assignmentButtonTitle(for: .primary)) {
                    assignLocal(to: .primary)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedCandidate == nil || model.isSelectedCandidateAssigned(to: .primary))

                Button(assignmentButtonTitle(for: .secondary)) {
                    assignLocal(to: .secondary)
                }
                .disabled(model.selectedCandidate == nil || model.isSelectedCandidateAssigned(to: .secondary))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var onlineFooter: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("S1 — основные · S2 — вторые")
                    .font(.caption.weight(.medium))
                Text(onlineFooterHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                openDownloadedSubtitlesFolder()
            } label: {
                Label(movieFolderURL == nil ? "Медиатека" : "Папка фильма", systemImage: "folder")
            }
            .help(movieFolderURL == nil
                ? "Открыть постоянную папку субтитров приложения"
                : "Открыть папку субтитров текущего фильма")
            .accessibilityLabel(movieFolderURL == nil
                ? "Открыть медиатеку интернет-субтитров"
                : "Открыть папку субтитров текущего фильма")

            Button("Закрыть") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if model.isDownloadingOnlineCandidate {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Загружаем выбранные субтитры")
                Button("Отменить загрузку") {
                    model.cancelOnlineDownload()
                }
            } else if !model.remoteCandidates.isEmpty {
                Button(onlineAssignmentButtonTitle(for: .primary)) {
                    assignOnline(to: .primary)
                }
                .buttonStyle(.borderedProminent)
                .disabled(onlineAssignmentIsDisabled(for: .primary))
                .accessibilityHint(onlineAssignmentHint(for: .primary))

                Button(onlineAssignmentButtonTitle(for: .secondary)) {
                    assignOnline(to: .secondary)
                }
                .disabled(onlineAssignmentIsDisabled(for: .secondary))
                .accessibilityHint(onlineAssignmentHint(for: .secondary))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func placeholder(
        symbol: String,
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(message: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Не получилось проверить папку")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack {
                Button("Выбрать другую папку…") {
                    model.chooseFolder()
                }
                Button("Повторить") {
                    model.startSearch()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var resultCountText: String {
        let count = model.candidates.count
        let ending: String
        let lastTwo = count % 100
        let last = count % 10
        if (11...14).contains(lastTwo) {
            ending = "вариантов"
        } else if last == 1 {
            ending = "вариант"
        } else if (2...4).contains(last) {
            ending = "варианта"
        } else {
            ending = "вариантов"
        }
        return "Найдено: \(count) \(ending)"
    }

    private var localFooterHint: String {
        if let selectedCandidate = model.selectedCandidate {
            return "Выбрано: \(selectedCandidate.displayName)"
        }
        switch model.phase {
        case .needsFolder:
            return "Сначала выберите папку"
        case .readyToSearch:
            return "Запустите поиск в выбранной папке"
        case .searching:
            return "Ищем наиболее подходящие варианты"
        case .results:
            return "Выберите файл в списке"
        case .empty:
            return "Попробуйте другую папку"
        case .failed:
            return "Повторите поиск или выберите другую папку"
        }
    }

    private func assignmentButtonTitle(for destination: SubtitleFinderDestination) -> String {
        model.isSelectedCandidateAssigned(to: destination)
            ? "Назначено \(destination.shortTitle)"
            : "Назначить \(destination.shortTitle)"
    }

    private var onlineResultCountText: String {
        resultCountText(for: model.remoteCandidates.count)
    }

    private var onlineFooterHint: String {
        if case .downloading(_, let destination) = model.onlinePhase {
            return "Загружаем субтитры для \(destination.shortTitle)…"
        }
        if let selectedCandidate = model.selectedRemoteCandidate {
            return "Выбрано: \(selectedCandidate.displayName)"
        }
        switch model.onlinePhase {
        case .idle:
            return "Введите запрос и выберите языки"
        case .searching:
            return "Ищем на OpenSubtitles.com"
        case .results, .downloading:
            return "Выберите результат"
        case .empty:
            return "Измените запрос или языки"
        case .failed:
            return "Исправьте ошибку и повторите действие"
        }
    }

    private func onlineAssignmentButtonTitle(for destination: SubtitleFinderDestination) -> String {
        if model.isSelectedRemoteCandidateAssigned(to: destination) {
            return "Назначено \(destination.shortTitle)"
        }
        if let selectedCandidate = model.selectedRemoteCandidate,
           model.isMaterialized(selectedCandidate) {
            return "Назначить \(destination.shortTitle)"
        }
        return "Загрузить в \(destination.shortTitle)"
    }

    private func onlineAssignmentIsDisabled(for destination: SubtitleFinderDestination) -> Bool {
        guard model.apiKeyState == .ready, let candidate = model.selectedRemoteCandidate else { return true }
        if model.isSelectedRemoteCandidateAssigned(to: destination) { return true }
        if model.supportsAccountAuthentication,
           model.accountState == .expired,
           !model.isMaterialized(candidate) {
            return true
        }
        return false
    }

    private func onlineAssignmentHint(for destination: SubtitleFinderDestination) -> String {
        guard let candidate = model.selectedRemoteCandidate else {
            return "Сначала выберите субтитры"
        }
        if model.isMaterialized(candidate) {
            return "Назначить уже загруженный файл как \(destination.title)"
        }
        return "Загрузить файл и назначить его как \(destination.title)"
    }

    private func assignLocal(to destination: SubtitleFinderDestination) {
        guard let candidate = model.assignSelected(to: destination) else { return }
        onAssign(candidate, destination)
    }

    private func assignOnline(to destination: SubtitleFinderDestination) {
        model.assignSelectedOnline(to: destination) { candidate, assignedDestination in
            onAssign(candidate, assignedDestination)
        }
    }

    private func openDownloadedSubtitlesFolder() {
        do {
            if let movieFolderURL {
                try SubtitleFileActions.openSubtitleFolder(movieFolderURL)
            } else {
                try SubtitleFileActions.openDownloadedSubtitlesFolder()
            }
        } catch {
            subtitleFileActionError = error.localizedDescription
        }
    }

    private func revealDownloadedCandidate(_ candidate: SubtitleFinderCandidate) {
        do {
            try SubtitleFileActions.revealInFinder(candidate.fileURL)
        } catch {
            subtitleFileActionError = error.localizedDescription
        }
    }

    private func saveDownloadedCandidate(_ candidate: SubtitleFinderCandidate) {
        SubtitleFileActions.presentSaveCopy(
            of: candidate.fileURL,
            suggestedName: candidate.displayName,
            initialDirectoryURL: movieFolderURL
        ) { result in
            if case .failure(let error) = result {
                subtitleFileActionError = error.localizedDescription
            }
        }
    }

    private func resultCountText(for count: Int) -> String {
        let ending: String
        let lastTwo = count % 100
        let last = count % 10
        if (11...14).contains(lastTwo) {
            ending = "вариантов"
        } else if last == 1 {
            ending = "вариант"
        } else if (2...4).contains(last) {
            ending = "варианта"
        } else {
            ending = "вариантов"
        }
        return "Найдено: \(count) \(ending)"
    }
}

private struct SubtitleFinderRemoteCandidateRow: View {
    let candidate: SubtitleFinderRemoteCandidate
    let isMaterialized: Bool
    let assignedDestinations: [SubtitleFinderDestination]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if candidate.isHashMatch {
                    Label("Точное совпадение", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12), in: Capsule())
                        .fixedSize()
                        .accessibilityLabel("Точное совпадение по хэшу видео")
                }

                Text(candidate.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                ForEach(assignedDestinations, id: \.self) { destination in
                    Text(destination.shortTitle)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Назначено как \(destination.title)")
                }

                if isMaterialized {
                    Label("Загружено", systemImage: "arrow.down.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            if let releaseName = candidate.releaseName, !releaseName.isEmpty {
                Text(releaseName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text(metadata)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityHint(
            isMaterialized
                ? "Файл уже загружен; его можно назначить, показать в Finder или сохранить копию"
                : "Выберите результат, затем загрузите его в S1 или S2"
        )
    }

    private var metadata: String {
        var parts = [candidate.languageName, candidate.formatName]
        if let framesPerSecond = candidate.framesPerSecond {
            parts.append("FPS \(formatFPS(framesPerSecond))")
        }
        if let rating = candidate.rating {
            parts.append("★ \(rating.formatted(.number.precision(.fractionLength(1))))")
        }
        if let downloadCount = candidate.downloadCount {
            parts.append("↓ \(downloadCount.formatted())")
        }
        return parts.joined(separator: " · ")
    }
}

private struct SubtitleFinderCandidateRow: View {
    let candidate: SubtitleFinderCandidate
    let assignedDestinations: [SubtitleFinderDestination]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            ForEach(assignedDestinations, id: \.self) { destination in
                Text(destination.shortTitle)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Назначено как \(destination.title)")
            }

            SubtitleFinderAssessmentBadge(assessment: candidate.assessment)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var metadata: String {
        [candidate.languageName, candidate.formatName, candidate.releaseName]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }
}

private struct SubtitleFinderAssessmentBadge: View {
    let assessment: SubtitleFinderAssessment

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        switch assessment {
        case .suitable:
            return "Подходит"
        case .timeOffset(let seconds):
            return "Смещение \(formatSigned(seconds)) с"
        case .frameRate(let subtitleFPS, let videoFPS):
            return "FPS \(formatFPS(subtitleFPS)) → \(formatFPS(videoFPS))"
        case .differentEdit:
            return "Другой монтаж"
        case .unverified:
            return "Не проверено"
        }
    }

    private var symbol: String {
        switch assessment {
        case .suitable: return "checkmark.circle.fill"
        case .timeOffset: return "clock.arrow.circlepath"
        case .frameRate: return "gauge.with.dots.needle.50percent"
        case .differentEdit: return "film.stack"
        case .unverified: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch assessment {
        case .suitable: return .green
        case .timeOffset: return .orange
        case .frameRate: return .blue
        case .differentEdit: return .red
        case .unverified: return .secondary
        }
    }

    private var accessibilityLabel: String {
        switch assessment {
        case .suitable:
            return "Подходит к видео"
        case .timeOffset(let seconds):
            return "Требуется смещение на \(formatSigned(seconds)) секунды"
        case .frameRate(let subtitleFPS, let videoFPS):
            return "Другая частота кадров: \(formatFPS(subtitleFPS)) вместо \(formatFPS(videoFPS))"
        case .differentEdit:
            return "Субтитры для другого монтажа"
        case .unverified:
            return "Совместимость не удалось проверить по аудио"
        }
    }
}

private struct SubtitleFinderAssessmentDetail: View {
    let assessment: SubtitleFinderAssessment

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: detailSymbol)
                .foregroundStyle(detailColor)
                .accessibilityHidden(true)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(detailColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var explanation: String {
        switch assessment {
        case .suitable:
            return "Время реплик совпадает с видео. Этот вариант можно использовать без дополнительной настройки."
        case .timeOffset(let seconds):
            return "Реплики совпадают после сдвига на \(formatSigned(seconds)) с. Это обычно легко исправить настройкой синхронизации."
        case .frameRate(let subtitleFPS, let videoFPS):
            return "Субтитры рассчитаны на \(formatFPS(subtitleFPS)) FPS, а видео — на \(formatFPS(videoFPS)) FPS. К концу фильма расхождение может увеличиваться."
        case .differentEdit:
            return "Порядок или длительность сцен заметно отличаются. Некоторые реплики могут не совпасть с видео."
        case .unverified:
            return "Файл найден, но системе не хватило данных, чтобы надёжно проверить его по аудио. Его можно загрузить и проверить вручную."
        }
    }

    private var detailSymbol: String {
        switch assessment {
        case .suitable: return "checkmark.circle.fill"
        case .timeOffset: return "clock.fill"
        case .frameRate: return "gauge.with.dots.needle.50percent"
        case .differentEdit: return "exclamationmark.triangle.fill"
        case .unverified: return "questionmark.circle.fill"
        }
    }

    private var detailColor: Color {
        switch assessment {
        case .suitable: return .green
        case .timeOffset: return .orange
        case .frameRate: return .blue
        case .differentEdit: return .red
        case .unverified: return .secondary
        }
    }
}

private func formatSigned(_ value: Double) -> String {
    let sign = value >= 0 ? "+" : "−"
    let number = abs(value).formatted(.number.precision(.fractionLength(1)))
    return sign + number
}

private func formatFPS(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...3)))
}
