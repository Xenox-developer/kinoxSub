import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        HStack(spacing: 0) {
            playerStage

            if controller.isSidebarVisible {
                Divider()
                SubtitleSidebarView(controller: controller, preferences: preferences)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: 850, minHeight: 540)
        .background(Color.black)
        .navigationTitle(controller.videoName ?? "KinoX Player")
        .toolbar { toolbarContent }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $controller.isDropTargeted) { providers in
            controller.handleDroppedProviders(providers)
        }
        .onOpenURL { url in
            if PlayerController.isSubtitleURL(url) {
                let slot: SubtitleSlot = controller.primaryTrack.isLoaded ? .secondary : .primary
                controller.loadSubtitle(url, into: slot)
            } else {
                controller.openVideo(url)
            }
        }
    }

    private var playerStage: some View {
        ZStack {
            Color.black

            if controller.hasVideo {
                AVPlayerContainerView(controller: controller, preferences: preferences)
            } else {
                WelcomeView(
                    openVideo: { controller.chooseVideo() },
                    openPrimarySubtitle: { controller.chooseSubtitle(for: .primary) },
                    openSecondarySubtitle: { controller.chooseSubtitle(for: .secondary) }
                )
            }

            loadingOverlay
            errorOverlay

            if controller.isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
                    .padding(18)
                    .overlay {
                        Label("Отпустите файл, чтобы открыть", systemImage: "arrow.down.doc.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.black.opacity(0.78), in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if case .loading(let name) = controller.loadingState {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Открываю \(name)…")
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(22)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Открывается видео \(name)")
        }
    }

    @ViewBuilder
    private var errorOverlay: some View {
        if case .failed(let message) = controller.loadingState {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.yellow)
                Text("Не удалось открыть видео")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                HStack {
                    Button("Закрыть") { controller.dismissError() }
                    Button("Выбрать другое…") { controller.chooseVideo() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(26)
            .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 28)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Ошибка открытия видео. \(message)")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: { controller.chooseVideo() }) {
                Image(systemName: "folder")
            }
            .help("Открыть видео (⌘O)")
            .accessibilityLabel("Открыть видео")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            trackToolbarButton(.primary)
            trackToolbarButton(.secondary)

            Divider()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    controller.isSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("Панель субтитров")
        }
    }

    private func trackToolbarButton(_ slot: SubtitleSlot) -> some View {
        let track = controller.track(for: slot)
        return Button {
            if track.isLoaded {
                controller.toggleTrack(slot)
            } else {
                controller.chooseSubtitle(for: slot)
            }
        } label: {
            HStack(spacing: 4) {
                Text(slot.shortTitle)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                Circle()
                    .fill(track.isLoaded && track.isEnabled ? (slot == .primary ? Color.accentColor : .orange) : .secondary)
                    .frame(width: 6, height: 6)
            }
        }
        .help(track.isLoaded ? "Включить или выключить \(slot.shortTitle)" : "Загрузить \(slot.shortTitle)")
        .accessibilityLabel(track.isLoaded ? "Включить или выключить \(slot.shortTitle)" : "Загрузить \(slot.shortTitle)")
        .accessibilityValue(track.isLoaded ? (track.isEnabled ? "включены" : "выключены") : "не загружены")
    }
}
