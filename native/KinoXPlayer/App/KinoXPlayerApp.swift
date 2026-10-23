import SwiftUI

@main
@MainActor
struct KinoXPlayerApp: App {
    @StateObject private var preferences: AppPreferences
    @StateObject private var controller: PlayerController
    @StateObject private var phraseAlignmentModels: PhraseAlignmentModelManager

    init() {
        let preferences = AppPreferences()
        let phraseAlignmentModels = PhraseAlignmentModelManager()
        _preferences = StateObject(wrappedValue: preferences)
        _phraseAlignmentModels = StateObject(wrappedValue: phraseAlignmentModels)
        _controller = StateObject(wrappedValue: PlayerController(
            preferences: preferences,
            phraseAlignmentModels: phraseAlignmentModels
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller, preferences: preferences)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_180, height: 720)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            KinoXCommands(controller: controller, preferences: preferences)
        }

        Settings {
            SettingsView(
                preferences: preferences,
                phraseAlignmentModels: phraseAlignmentModels
            )
        }
    }
}

private struct KinoXCommands: Commands {
    let controller: PlayerController
    let preferences: AppPreferences

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Открыть видео…") {
                Task { @MainActor in controller.chooseVideo() }
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Загрузить основные субтитры…") {
                Task { @MainActor in controller.chooseSubtitle(for: .primary) }
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])

            Button("Загрузить вторые субтитры…") {
                Task { @MainActor in controller.chooseSubtitle(for: .secondary) }
            }
            .keyboardShortcut("2", modifiers: [.command, .shift])
        }

        CommandMenu("Воспроизведение") {
            Button("Пауза / воспроизведение") {
                Task { @MainActor in controller.togglePlayback() }
            }
            .keyboardShortcut(.space, modifiers: [])

            Divider()

            Button("Назад") {
                Task { @MainActor in controller.seek(by: -preferences.skipInterval) }
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("Вперёд") {
                Task { @MainActor in controller.seek(by: preferences.skipInterval) }
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Divider()

            Button("Громче") {
                Task { @MainActor in controller.adjustVolume(by: 0.05) }
            }
            .keyboardShortcut(.upArrow, modifiers: [])

            Button("Тише") {
                Task { @MainActor in controller.adjustVolume(by: -0.05) }
            }
            .keyboardShortcut(.downArrow, modifiers: [])

            Button("Выключить звук") {
                Task { @MainActor in controller.toggleMute() }
            }
            .keyboardShortcut("m", modifiers: [])

            Divider()

            Button("Уменьшить скорость") {
                Task { @MainActor in controller.adjustPlaybackRate(up: false) }
            }
            .keyboardShortcut("[", modifiers: [])

            Button("Увеличить скорость") {
                Task { @MainActor in controller.adjustPlaybackRate(up: true) }
            }
            .keyboardShortcut("]", modifiers: [])

            Button("Обычная скорость") {
                Task { @MainActor in controller.setPlaybackRate(1) }
            }
            .keyboardShortcut("\\", modifiers: [])
        }

        CommandMenu("Субтитры") {
            Button("Включить / выключить S1") {
                Task { @MainActor in controller.toggleTrack(.primary) }
            }
            .keyboardShortcut("1", modifiers: [])

            Button("Включить / выключить S2") {
                Task { @MainActor in controller.toggleTrack(.secondary) }
            }
            .keyboardShortcut("2", modifiers: [])

            Divider()

            Menu("Синхронизация S1") {
                Button("Подогнать автоматически") {
                    Task { @MainActor in controller.synchronizeSubtitle(for: .primary) }
                }
                Divider()
                Button("На 0,5 с раньше") {
                    Task { @MainActor in controller.adjustOffset(for: .primary, by: -0.5) }
                }
                Button("На 0,5 с позже") {
                    Task { @MainActor in controller.adjustOffset(for: .primary, by: 0.5) }
                }
                Button("Сбросить всю коррекцию") {
                    Task { @MainActor in controller.resetSubtitleSynchronization(for: .primary) }
                }
            }

            Menu("Синхронизация S2") {
                Button("Подогнать автоматически") {
                    Task { @MainActor in controller.synchronizeSubtitle(for: .secondary) }
                }
                Divider()
                Button("На 0,5 с раньше") {
                    Task { @MainActor in controller.adjustOffset(for: .secondary, by: -0.5) }
                }
                Button("На 0,5 с позже") {
                    Task { @MainActor in controller.adjustOffset(for: .secondary, by: 0.5) }
                }
                Button("Сбросить всю коррекцию") {
                    Task { @MainActor in controller.resetSubtitleSynchronization(for: .secondary) }
                }
            }

            Divider()

            Button("Показать / скрыть панель субтитров") {
                Task { @MainActor in controller.isSidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
    }
}
