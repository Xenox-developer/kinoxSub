import AVFoundation
import AVKit
import SwiftUI

struct AVPlayerContainerView: NSViewRepresentable {
    @ObservedObject var controller: PlayerController
    @ObservedObject var preferences: AppPreferences

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = controller.player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.showsFrameSteppingButtons = true
        playerView.videoGravity = preferences.fillVideo ? .resizeAspectFill : .resizeAspect
        context.coordinator.ensureOverlay(
            in: playerView,
            controller: controller,
            preferences: preferences
        )

        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        if playerView.player !== controller.player {
            playerView.player = controller.player
        }
        playerView.videoGravity = preferences.fillVideo ? .resizeAspectFill : .resizeAspect
        context.coordinator.ensureOverlay(
            in: playerView,
            controller: controller,
            preferences: preferences
        )
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
        coordinator.detachOverlay()
        playerView.player = nil
    }

    final class Coordinator {
        private static let overlayIdentifier = NSUserInterfaceItemIdentifier(
            "KinoXPlayer.SubtitleOverlay"
        )

        private var hostingView: PassThroughHostingView<SubtitleOverlayView>?
        private weak var mountedContainer: NSView?
        private var overlayConstraints: [NSLayoutConstraint] = []
        private var controllerIdentifier: ObjectIdentifier?
        private var preferencesIdentifier: ObjectIdentifier?

        func ensureOverlay(
            in playerView: AVPlayerView,
            controller: PlayerController,
            preferences: AppPreferences
        ) {
            guard let overlayContainer = playerView.contentOverlayView else { return }

            let nextControllerIdentifier = ObjectIdentifier(controller)
            let nextPreferencesIdentifier = ObjectIdentifier(preferences)
            if hostingView == nil
                || controllerIdentifier != nextControllerIdentifier
                || preferencesIdentifier != nextPreferencesIdentifier {
                detachOverlay()

                let hostingView = PassThroughHostingView(
                    rootView: SubtitleOverlayView(
                        controller: controller,
                        preferences: preferences
                    )
                )
                hostingView.identifier = Self.overlayIdentifier
                hostingView.sizingOptions = []
                hostingView.translatesAutoresizingMaskIntoConstraints = false

                self.hostingView = hostingView
                controllerIdentifier = nextControllerIdentifier
                preferencesIdentifier = nextPreferencesIdentifier
            }

            guard let hostingView else { return }

            // A representable can briefly be rebuilt while AVPlayerView changes
            // presentation mode. Remove any orphaned subtitle hosts before
            // mounting the coordinator-owned instance.
            let staleOverlayViews = overlayContainer.subviews.filter {
                $0.identifier == Self.overlayIdentifier && $0 !== hostingView
            }
            staleOverlayViews.forEach { $0.removeFromSuperview() }

            let needsMount = hostingView.superview !== overlayContainer
                || mountedContainer !== overlayContainer
                || overlayConstraints.count != 4
                || overlayConstraints.contains(where: { !$0.isActive })
            guard needsMount else { return }

            unmountOverlay()
            overlayContainer.addSubview(hostingView)
            overlayConstraints = [
                hostingView.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: overlayContainer.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor),
            ]
            NSLayoutConstraint.activate(overlayConstraints)
            mountedContainer = overlayContainer
        }

        func detachOverlay() {
            unmountOverlay()
            hostingView = nil
            controllerIdentifier = nil
            preferencesIdentifier = nil
        }

        private func unmountOverlay() {
            NSLayoutConstraint.deactivate(overlayConstraints)
            overlayConstraints.removeAll()
            hostingView?.removeFromSuperview()
            mountedContainer = nil
        }
    }
}

final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
