# KinoX — Dual Subtitles

Watch videos with two independent subtitle tracks: the original dialogue and a translation. The project includes a native macOS player and a Chrome/Edge extension.

| | KinoX Player | KinoX Dual Subtitles |
| --- | --- | --- |
| Platform | macOS 13+ | Chrome / Edge, Manifest V3 |
| Video source | Local files | HTML5 players on `kinox.to` and its subdomains |
| Subtitles | Two SRT / WebVTT tracks | Two SRT / WebVTT tracks |
| Synchronization | Manual offsets, speech-based alignment, drift correction | Manual offsets and audio-based offset detection |
| Subtitle search | Local folders and OpenSubtitles.com | User-selected files |
| Source code | [`native/`](native/) | Repository root |

## Quick Start

Clone the repository, or download and extract it using **Code → Download ZIP**:

```sh
git clone https://github.com/Xenox-developer/kinoxSub.git
cd kinoxSub
```

### macOS App

Building requires Xcode with the macOS SDK and command-line tools. The first build needs an internet connection to download Swift dependencies; versions are pinned in the project and `Package.resolved`.

```sh
./native/Scripts/build-release.sh
open native/dist/KinoXPlayer.app
```

The script creates an app with a local ad-hoc signature. Built `.app` bundles and downloadable language models are not included in the repository. For development, open `native/KinoXPlayer.xcodeproj`, select the **KinoXPlayer** scheme and **My Mac** destination, then press `Command–R`.

Open a video with `Command–O` or drag it into the window. Load the original subtitles into **S1** and the translation into **S2**. Each track can be enabled, replaced, styled, and shifted independently. A positive offset delays subtitles; a negative offset shows them earlier.

Features include:

- automatic alignment to speech, including constant offsets and accumulated timing drift;
- matching SRT/VTT files from local folders and OpenSubtitles.com;
- semantic matching of S1 ↔ S2 phrases using an optional local model;
- separate font, color, background, and position settings for each track;
- fullscreen playback, 0.5–2× speed, and playback position persistence;
- a Russian-language interface and keyboard shortcuts.

OpenSubtitles.com search requires a personal API key, entered in the app and stored in macOS Keychain. To enable semantic phrase matching, install the model through **Settings → Subtitles → Phrase Matching**. The download is approximately 245 MB; subsequent processing runs locally. The app currently uses Russian UI labels; control names in this documentation are translated into English.

See the [KinoX Player guide](native/README.md) for detailed setup, search, and playback instructions.

### Chrome / Edge Extension

No build step or npm dependency installation is required.

1. Open `chrome://extensions` or `edge://extensions`.
2. Enable **Developer mode** and click **Load unpacked**.
3. Select the repository root: the folder containing `manifest.json`.
4. Open a movie on `kinox.to`, start playback, and click the purple **CC²** button in the bottom-right corner.
5. Load the original subtitles into track 1 and the translation into track 2.

UTF-8, UTF-16, Windows-1251, and Windows-1252 encodings are supported. Settings and selected subtitles are saved in the extension's local storage. After updating the source files, reload the extension on its management page and refresh the movie tab.

For automatic synchronization, find a scene with ordinary dialogue, click **Auto-sync · 30 s**, and keep the video playing until analysis finishes. The extension compares audio activity with subtitle intervals and applies an offset when confidence is sufficient. Offsets greater than 30 seconds are rejected. The extension's controls also currently use Russian labels.

## Limitations

- **macOS video formats.** The app uses AVKit/AVFoundation. MP4, M4V, and MOV with system-supported codecs are preferred. MKV, AVI, WebM, and some audio tracks may not play; there is no built-in transcoding.
- **Subtitle formats.** SRT and WebVTT are supported. ASS/SSA effects and karaoke are not supported.
- **Automatic synchronization.** Music, audio commentary, alternate edits, and different dubbing can reduce accuracy. Use manual offsets when needed.
- **Browser players.** The extension requires an accessible HTML5 `<video>` element. Auto-sync also requires audio access through browser APIs, which some players restrict. Fullscreen playback uses a custom overlay; when the video element itself enters fullscreen, a native WebVTT track serves as a fallback.
- **Picture in Picture.** Custom dual subtitles may not appear in the macOS system PiP window.
- **App distribution.** A local ad-hoc signature does not replace Developer ID signing and notarization for distribution without Gatekeeper warnings.

## Privacy and Permissions

The extension requests access to all websites to locate players inside frames hosted by different video services. It only allows operation in tabs whose top-level page is on `kinox.to` or one of its subdomains. Subtitle processing and auto-sync run locally; audio is neither saved to a file nor sent to external services.

The macOS app processes video, audio, and subtitles locally. Internet access is used for user-requested subtitle search and downloads, and for installing the optional language model. During online searches, OpenSubtitles receives the title, selected languages, video file size and hash, IP address, and app version. The video, audio, and full file path are not uploaded. See [online search and data storage](native/README.md#online-search) for details.

## Testing

Extension tests require Node.js 18+ and run without third-party npm packages:

```sh
npm test
```

Run the macOS app tests with:

```sh
xcodebuild \
  -project native/KinoXPlayer.xcodeproj \
  -scheme KinoXPlayer \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test
```

## Project Structure

```text
.
├── manifest.json        # Extension Manifest V3
├── background.js        # State and messaging between frames
├── content.js           # Video discovery, UI, and subtitle rendering
├── subtitle-parser.js   # SRT/WebVTT parsing and encoding detection
├── autosync.js          # Offset estimation from audio activity
├── styles.css           # Extension styles
├── test/                # Extension tests
└── native/
    ├── KinoXPlayer/      # SwiftUI, AVKit, subtitles, and online search
    ├── KinoXPlayerTests/ # App tests
    ├── KinoXPlayer.xcodeproj/
    ├── Scripts/         # Release build script
    └── README.md        # Detailed macOS guide
```

## Feedback

Report bugs and suggest improvements through [Issues](https://github.com/Xenox-developer/kinoxSub/issues). For bug reports, include your macOS or browser version, steps to reproduce, and expected behavior. Only attach subtitle samples you have permission to share, and keep API keys and passwords out of reports.
