import SwiftUI

struct WelcomeView: View {
    let openVideo: () -> Void
    let openPrimarySubtitle: () -> Void
    let openSecondarySubtitle: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.045, blue: 0.07), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.accentColor.opacity(0.13))
                .frame(width: 520, height: 520)
                .blur(radius: 80)
                .offset(x: -280, y: -210)

            VStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 25, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color(red: 0.46, green: 0.25, blue: 0.92)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 92, height: 72)
                        .shadow(color: Color.accentColor.opacity(0.32), radius: 26, y: 12)

                    Image(systemName: "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 3)

                    Text("2")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                        .offset(x: 39, y: -30)
                }
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("KinoX Player")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Видео и две независимые дорожки субтитров")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.62))
                }

                Button(action: openVideo) {
                    Label("Открыть видео", systemImage: "folder")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(minWidth: 180, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)

                VStack(spacing: 5) {
                    Text("или перетащите файл в это окно")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                    Text("MP4 · MOV · M4V · системные кодеки macOS")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.52))
                }

                HStack(spacing: 10) {
                    Button(action: openPrimarySubtitle) {
                        Label("Загрузить S1", systemImage: "captions.bubble")
                    }
                    Button(action: openSecondarySubtitle) {
                        Label("Загрузить S2", systemImage: "captions.bubble.fill")
                    }
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.white.opacity(0.78))
            }
            .padding(48)
        }
        .accessibilityElement(children: .contain)
    }
}
