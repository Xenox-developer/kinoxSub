import Combine
import Foundation

@MainActor
public final class AppPreferences: ObservableObject {
    public static let shared = AppPreferences()

    @Published public var autoPlay: Bool {
        didSet { defaults.set(autoPlay, forKey: Key.autoPlay) }
    }

    @Published public var resumePlayback: Bool {
        didSet { defaults.set(resumePlayback, forKey: Key.resumePlayback) }
    }

    @Published public var skipInterval: TimeInterval {
        didSet { defaults.set(skipInterval, forKey: Key.skipInterval) }
    }

    @Published public var defaultPlaybackRate: Double {
        didSet { defaults.set(defaultPlaybackRate, forKey: Key.defaultPlaybackRate) }
    }

    @Published public var rememberVolume: Bool {
        didSet { defaults.set(rememberVolume, forKey: Key.rememberVolume) }
    }

    @Published public var lastVolume: Double {
        didSet { defaults.set(lastVolume, forKey: Key.lastVolume) }
    }

    @Published public var primaryFontSize: Double {
        didSet { defaults.set(primaryFontSize, forKey: Key.primaryFontSize) }
    }

    @Published public var secondaryFontSize: Double {
        didSet { defaults.set(secondaryFontSize, forKey: Key.secondaryFontSize) }
    }

    @Published public var primaryColorHex: String {
        didSet { defaults.set(primaryColorHex, forKey: Key.primaryColorHex) }
    }

    @Published public var secondaryColorHex: String {
        didSet { defaults.set(secondaryColorHex, forKey: Key.secondaryColorHex) }
    }

    @Published public var subtitleBackgroundOpacity: Double {
        didSet { defaults.set(subtitleBackgroundOpacity, forKey: Key.subtitleBackgroundOpacity) }
    }

    @Published public var subtitleBottomInset: Double {
        didSet { defaults.set(subtitleBottomInset, forKey: Key.subtitleBottomInset) }
    }

    @Published public var boldSubtitles: Bool {
        didSet { defaults.set(boldSubtitles, forKey: Key.boldSubtitles) }
    }

    @Published public var showSubtitleBackground: Bool {
        didSet { defaults.set(showSubtitleBackground, forKey: Key.showSubtitleBackground) }
    }

    @Published public var fillVideo: Bool {
        didSet { defaults.set(fillVideo, forKey: Key.fillVideo) }
    }

    @Published public var showSidebarOnLaunch: Bool {
        didSet { defaults.set(showSidebarOnLaunch, forKey: Key.showSidebarOnLaunch) }
    }

    @Published public var automaticallySynchronizeSubtitles: Bool {
        didSet {
            defaults.set(
                automaticallySynchronizeSubtitles,
                forKey: Key.automaticallySynchronizeSubtitles
            )
        }
    }

    @Published public var phraseLinkingEnabled: Bool {
        didSet { defaults.set(phraseLinkingEnabled, forKey: Key.phraseLinkingEnabled) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        autoPlay = Self.boolValue(in: defaults, forKey: Key.autoPlay, fallback: Default.autoPlay)
        resumePlayback = Self.boolValue(
            in: defaults,
            forKey: Key.resumePlayback,
            fallback: Default.resumePlayback
        )
        skipInterval = Self.doubleValue(
            in: defaults,
            forKey: Key.skipInterval,
            fallback: Default.skipInterval
        )
        defaultPlaybackRate = Self.doubleValue(
            in: defaults,
            forKey: Key.defaultPlaybackRate,
            fallback: Default.defaultPlaybackRate
        )
        rememberVolume = Self.boolValue(
            in: defaults,
            forKey: Key.rememberVolume,
            fallback: Default.rememberVolume
        )
        lastVolume = Self.doubleValue(
            in: defaults,
            forKey: Key.lastVolume,
            fallback: Default.lastVolume
        )
        primaryFontSize = Self.doubleValue(
            in: defaults,
            forKey: Key.primaryFontSize,
            fallback: Default.primaryFontSize
        )
        secondaryFontSize = Self.doubleValue(
            in: defaults,
            forKey: Key.secondaryFontSize,
            fallback: Default.secondaryFontSize
        )
        primaryColorHex = defaults.string(forKey: Key.primaryColorHex) ?? Default.primaryColorHex
        secondaryColorHex = defaults.string(forKey: Key.secondaryColorHex) ?? Default.secondaryColorHex
        subtitleBackgroundOpacity = Self.doubleValue(
            in: defaults,
            forKey: Key.subtitleBackgroundOpacity,
            fallback: Default.subtitleBackgroundOpacity
        )
        subtitleBottomInset = Self.doubleValue(
            in: defaults,
            forKey: Key.subtitleBottomInset,
            fallback: Default.subtitleBottomInset
        )
        boldSubtitles = Self.boolValue(
            in: defaults,
            forKey: Key.boldSubtitles,
            fallback: Default.boldSubtitles
        )
        showSubtitleBackground = Self.boolValue(
            in: defaults,
            forKey: Key.showSubtitleBackground,
            fallback: Default.showSubtitleBackground
        )
        fillVideo = Self.boolValue(in: defaults, forKey: Key.fillVideo, fallback: Default.fillVideo)
        showSidebarOnLaunch = Self.boolValue(
            in: defaults,
            forKey: Key.showSidebarOnLaunch,
            fallback: Default.showSidebarOnLaunch
        )
        automaticallySynchronizeSubtitles = Self.boolValue(
            in: defaults,
            forKey: Key.automaticallySynchronizeSubtitles,
            fallback: Default.automaticallySynchronizeSubtitles
        )
        phraseLinkingEnabled = Self.boolValue(
            in: defaults,
            forKey: Key.phraseLinkingEnabled,
            fallback: Default.phraseLinkingEnabled
        )
    }

    public func resetSubtitleAppearance() {
        primaryFontSize = Default.primaryFontSize
        secondaryFontSize = Default.secondaryFontSize
        primaryColorHex = Default.primaryColorHex
        secondaryColorHex = Default.secondaryColorHex
        subtitleBackgroundOpacity = Default.subtitleBackgroundOpacity
        subtitleBottomInset = Default.subtitleBottomInset
        boldSubtitles = Default.boldSubtitles
        showSubtitleBackground = Default.showSubtitleBackground
    }
}

private extension AppPreferences {
    enum Key {
        static let autoPlay = "preferences.autoPlay"
        static let resumePlayback = "preferences.resumePlayback"
        static let skipInterval = "preferences.skipInterval"
        static let defaultPlaybackRate = "preferences.defaultPlaybackRate"
        static let rememberVolume = "preferences.rememberVolume"
        static let lastVolume = "preferences.lastVolume"
        static let primaryFontSize = "preferences.primaryFontSize"
        static let secondaryFontSize = "preferences.secondaryFontSize"
        static let primaryColorHex = "preferences.primaryColorHex"
        static let secondaryColorHex = "preferences.secondaryColorHex"
        static let subtitleBackgroundOpacity = "preferences.subtitleBackgroundOpacity"
        static let subtitleBottomInset = "preferences.subtitleBottomInset"
        static let boldSubtitles = "preferences.boldSubtitles"
        static let showSubtitleBackground = "preferences.showSubtitleBackground"
        static let fillVideo = "preferences.fillVideo"
        static let showSidebarOnLaunch = "preferences.showSidebarOnLaunch"
        static let automaticallySynchronizeSubtitles = "preferences.automaticallySynchronizeSubtitles"
        static let phraseLinkingEnabled = "preferences.phraseLinkingEnabled"
    }

    enum Default {
        static let autoPlay = false
        static let resumePlayback = true
        static let skipInterval: TimeInterval = 10
        static let defaultPlaybackRate = 1.0
        static let rememberVolume = true
        static let lastVolume = 1.0
        static let primaryFontSize = 30.0
        static let secondaryFontSize = 23.0
        static let primaryColorHex = "#FFFFFF"
        static let secondaryColorHex = "#FFD966"
        static let subtitleBackgroundOpacity = 0.65
        static let subtitleBottomInset = 72.0
        static let boldSubtitles = false
        static let showSubtitleBackground = true
        static let fillVideo = false
        static let showSidebarOnLaunch = true
        static let automaticallySynchronizeSubtitles = true
        static let phraseLinkingEnabled = false
    }

    static func boolValue(
        in defaults: UserDefaults,
        forKey key: String,
        fallback: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    static func doubleValue(
        in defaults: UserDefaults,
        forKey key: String,
        fallback: Double
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.double(forKey: key)
    }
}
