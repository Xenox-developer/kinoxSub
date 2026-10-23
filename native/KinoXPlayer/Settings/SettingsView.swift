import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject private var preferences: AppPreferences
    @ObservedObject private var phraseAlignmentModels: PhraseAlignmentModelManager

    init(
        preferences: AppPreferences = .shared,
        phraseAlignmentModels: PhraseAlignmentModelManager
    ) {
        self.preferences = preferences
        self.phraseAlignmentModels = phraseAlignmentModels
    }

    var body: some View {
        TabView {
            GeneralSettingsView(preferences: preferences)
                .tabItem {
                    Label("Общие", systemImage: "gearshape")
                }

            PlaybackSettingsView(preferences: preferences)
                .tabItem {
                    Label("Воспроизведение", systemImage: "play.circle")
                }

            SubtitleSettingsView(
                preferences: preferences,
                phraseAlignmentModels: phraseAlignmentModels
            )
                .tabItem {
                    Label("Субтитры", systemImage: "captions.bubble")
                }
        }
        .frame(width: 560, height: 520)
    }
}

@MainActor
private struct GeneralSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section("При открытии видео") {
                Toggle("Начинать воспроизведение автоматически", isOn: $preferences.autoPlay)
                Toggle("Продолжать с последней позиции", isOn: $preferences.resumePlayback)
            }

            Section("Интерфейс") {
                Toggle("Показывать боковую панель при запуске", isOn: $preferences.showSidebarOnLaunch)
                Toggle("Заполнять видео всю область окна", isOn: $preferences.fillVideo)
                    .help("Видео может быть обрезано по краям, чтобы полностью заполнить окно.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

@MainActor
private struct PlaybackSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    private let skipIntervals: [TimeInterval] = [5, 10, 15, 30]
    private let playbackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Form {
            Section("Перемотка") {
                Picker("Шаг перемотки", selection: $preferences.skipInterval) {
                    ForEach(skipIntervals, id: \.self) { interval in
                        Text("\(Int(interval)) сек.").tag(interval)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Скорость") {
                Picker("Скорость по умолчанию", selection: $preferences.defaultPlaybackRate) {
                    ForEach(playbackRates, id: \.self) { rate in
                        Text(rateLabel(rate)).tag(rate)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Громкость") {
                Toggle("Запоминать громкость", isOn: $preferences.rememberVolume)

                LabeledContent("Последняя громкость") {
                    HStack(spacing: 10) {
                        Slider(value: $preferences.lastVolume, in: 0...1, step: 0.01)
                            .frame(width: 230)
                            .accessibilityLabel("Последняя громкость")
                            .accessibilityValue("\(Int((preferences.lastVolume * 100).rounded())) процентов")
                        Text("\(Int((preferences.lastVolume * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                .disabled(!preferences.rememberVolume)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == 1 ? "Обычная (1×)" : "\(rate.formatted())×"
    }
}

@MainActor
private struct SubtitleSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var phraseAlignmentModels: PhraseAlignmentModelManager
    @State private var isRemoveModelConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GroupBox("Автоматическая синхронизация") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "Подгонять субтитры к видео после загрузки",
                            isOn: $preferences.automaticallySynchronizeSubtitles
                        )
                        Text("Приложение локально сравнивает интервалы речи с репликами и исправляет сдвиг и постепенный дрейф. Видео и звук никуда не отправляются.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                }

                phraseLinkingSection

                subtitleTrackSection(
                    title: "Основные субтитры",
                    fontSize: $preferences.primaryFontSize,
                    color: primaryColor
                )

                subtitleTrackSection(
                    title: "Дополнительные субтитры",
                    fontSize: $preferences.secondaryFontSize,
                    color: secondaryColor
                )

                GroupBox("Общий стиль") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Полужирный текст", isOn: $preferences.boldSubtitles)
                        Toggle("Показывать фон субтитров", isOn: $preferences.showSubtitleBackground)

                        sliderRow(
                            title: "Непрозрачность фона",
                            value: $preferences.subtitleBackgroundOpacity,
                            range: 0...1,
                            step: 0.05,
                            valueText: "\(Int((preferences.subtitleBackgroundOpacity * 100).rounded()))%"
                        )
                        .disabled(!preferences.showSubtitleBackground)

                        sliderRow(
                            title: "Отступ снизу",
                            value: $preferences.subtitleBottomInset,
                            range: 0...140,
                            step: 2,
                            valueText: "\(Int(preferences.subtitleBottomInset)) пт"
                        )
                    }
                    .padding(8)
                }

                SubtitlePreview(preferences: preferences)

                HStack {
                    Spacer()
                    Button("Сбросить оформление") {
                        preferences.resetSubtitleAppearance()
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            if !phraseAlignmentModels.isReady {
                preferences.phraseLinkingEnabled = false
            }
        }
        .onChange(of: phraseAlignmentModels.isReady) { isReady in
            preferences.phraseLinkingEnabled = isReady
        }
        .confirmationDialog(
            "Удалить языковую модель?",
            isPresented: $isRemoveModelConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Удалить модель", role: .destructive) {
                preferences.phraseLinkingEnabled = false
                phraseAlignmentModels.removeModel()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Освободится около 245 МБ. Для связывания фраз модель потребуется скачать снова.")
        }
    }

    private var phraseLinkingSection: some View {
        GroupBox("Связывание фраз") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Сопоставляет эквивалентные реплики S1 и S2, даже если их границы и тайминги немного различаются.")
                    .fixedSize(horizontal: false, vertical: true)

                phraseAlignmentModelControls

                Text("Для работы нужно один раз скачать языковую модель размером около 245 МБ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(
                    "Обработка выполняется локально на этом Mac. Текст субтитров никуда не отправляется.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var phraseAlignmentModelControls: some View {
        switch phraseAlignmentModels.state {
        case .notInstalled:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Модель не установлена")
                        .font(.callout.weight(.medium))
                    Text("После установки связывание включится автоматически.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Установить · ~245 МБ") {
                    phraseAlignmentModels.install()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Скачивает языковую модель размером около 245 мегабайт")
            }

        case .downloading(let progress):
            let normalizedProgress = normalizedModelProgress(progress)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Загрузка модели…")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(Int((normalizedProgress * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Отменить") {
                        phraseAlignmentModels.cancelInstallation()
                    }
                }
                ProgressView(value: normalizedProgress, total: 1)
                    .accessibilityLabel("Загрузка языковой модели")
                    .accessibilityValue(
                        "\(Int((normalizedProgress * 100).rounded())) процентов"
                    )
            }

        case .compiling:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Подготовка языковой модели")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Подготавливаем модель…")
                        .font(.callout.weight(.medium))
                    Text("Обычно это занимает меньше минуты.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отменить") {
                    phraseAlignmentModels.cancelInstallation()
                }
            }

        case .ready:
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Связывать эквивалентные реплики S1 и S2",
                    isOn: $preferences.phraseLinkingEnabled
                )
                .disabled(!phraseAlignmentModels.isReady)
                .accessibilityHint("Объединяет соответствующие фразы двух дорожек субтитров")

                HStack {
                    Label("Модель установлена", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Удалить модель…", role: .destructive) {
                        isRemoveModelConfirmationPresented = true
                    }
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Не удалось установить модель", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Повторить") {
                        phraseAlignmentModels.install()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Удалить загруженные данные…", role: .destructive) {
                        isRemoveModelConfirmationPresented = true
                    }
                }
            }
        }
    }

    private func normalizedModelProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }

    private func subtitleTrackSection(
        title: String,
        fontSize: Binding<Double>,
        color: Binding<Color>
    ) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    title: "Размер шрифта",
                    value: fontSize,
                    range: 14...52,
                    step: 1,
                    valueText: "\(Int(fontSize.wrappedValue)) пт"
                )
                ColorPicker("Цвет текста", selection: color, supportsOpacity: false)
            }
            .padding(8)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step)
                    .frame(width: 230)
                    .accessibilityLabel(title)
                    .accessibilityValue(valueText)
                Text(valueText)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    private var primaryColor: Binding<Color> {
        Binding(
            get: { Color(hex: preferences.primaryColorHex) ?? .white },
            set: { preferences.primaryColorHex = $0.hexString() ?? "#FFFFFF" }
        )
    }

    private var secondaryColor: Binding<Color> {
        Binding(
            get: { Color(hex: preferences.secondaryColorHex) ?? .yellow },
            set: { preferences.secondaryColorHex = $0.hexString() ?? "#FFD966" }
        )
    }
}

@MainActor
private struct SubtitlePreview: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        GroupBox("Предпросмотр") {
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.24, blue: 0.34), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white.opacity(0.16))

                VStack(spacing: 5) {
                    subtitleLine(
                        "Manchmal lohnt es sich, neu anzufangen.",
                        size: previewSize(preferences.secondaryFontSize),
                        color: Color(hex: preferences.secondaryColorHex) ?? .yellow
                    )
                    subtitleLine(
                        "Иногда стоит начать всё сначала.",
                        size: previewSize(preferences.primaryFontSize),
                        color: Color(hex: preferences.primaryColorHex) ?? .white
                    )
                }
                .padding(.horizontal, 18)
                .padding(.bottom, preferences.subtitleBottomInset * 0.55)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(8)
        }
    }

    private func subtitleLine(_ text: String, size: Double, color: Color) -> some View {
        Text(text)
            .font(.system(size: size, weight: preferences.boldSubtitles ? .bold : .regular))
            .foregroundColor(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Color.black.opacity(
                    preferences.showSubtitleBackground ? preferences.subtitleBackgroundOpacity : 0
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func previewSize(_ configuredSize: Double) -> Double {
        min(max(configuredSize * 0.65, 12), 25)
    }
}
