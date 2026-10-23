# KinoXPlayer for macOS

KinoXPlayer is a macOS video player with two independent external subtitle tracks. Playback and synchronization analysis run locally on your Mac. Online search is used only when requested by the user.

The app currently has a Russian-language interface. Control and menu names below are translated into English for readability.

## Features

- Open videos using the file picker, Finder, or drag and drop.
- Load, replace, disable, and remove two independent SRT/WebVTT tracks.
- Find local subtitles near the movie file and check them against the actual audio.
- Search and download subtitles from OpenSubtitles.com in Russian, German, and other languages.
- Find exact video matches using a file hash without uploading the movie.
- Automatically align either subtitle track to speech in the movie.
- Match equivalent S1 and S2 phrases locally using semantic similarity and surrounding context.
- Detect constant offsets, gradual drift/FPS differences, and likely mismatched edits.
- Apply timing corrections without modifying the original SRT/VTT file.
- Adjust S1 and S2 independently in 0.5-second steps or with a fine-grained slider.
- Customize each track's color and font size, plus background, bold styling, and position.
- Use system AVPlayer controls, fullscreen playback, and 0.5–2× speed.
- Restore settings, volume, and playback position.
- Use keyboard shortcuts: `Space`, arrow keys, `M`, `1`/`2`, `[`/`]`, and `Command–O`.
- Access core controls with VoiceOver.

Open settings with `Command–,`. A positive offset delays subtitles; a negative offset shows them earlier.

### S1 ↔ S2 Phrase Matching

Install the optional local language model through **Settings → Subtitles → Phrase Matching**. The one-time download is approximately 245 MB. Matching is enabled automatically after installation and then works offline. Subtitle text stays on your Mac.

The app first synchronizes both tracks with the video, then compares phrases by timing, order, and meaning. Matched translations share the S1 display interval. When no confident match is found, the cue is displayed independently. Original SRT/VTT files remain unchanged.

The **S1 ↔ S2 Matching** section in the right sidebar shows the proportion of matched phrases and lets you run matching again. Initial analysis of a full movie may take several tens of seconds on Apple Silicon. Results and semantic embeddings are cached for faster subsequent loads.

## Running the App

The repository does not include a prebuilt `.app`. First [build the app](#building-with-the-script); the script creates `native/dist` and places the result there.

1. Open `native/dist` in Finder.
2. Launch `KinoXPlayer.app`.
3. Open a video using the app menu or `Command–O`.
4. Load the first and second subtitle tracks using their buttons or menu commands.

By default, loading a track starts speech-based analysis to correct its initial offset and accumulated drift. The right sidebar shows the detected correction and confidence. Click **Align Automatically** on the S1 or S2 card to analyze it again. **Reset All** removes both automatic and manual timing corrections. Automatic alignment on load can be disabled under **Settings → Subtitles**, while manual analysis remains available.

To find suitable local files, open the right sidebar and click **Find Matching Subtitles…**. Select a folder containing SRT/VTT files and start analysis. Initial movie analysis typically takes 20–40 seconds; later checks reuse an audio profile held in memory. Speech activity analysis uses local macOS APIs: video and subtitles are not uploaded, and microphone permission is not required.

Results marked **Offset** or **FPS** can be assigned directly to S1 or S2, and the detected correction is applied automatically. The source subtitle file remains unchanged. Matching is probabilistic: music, audio commentary, and substantially different dubbing may require manual review. Corrections with insufficient confidence are not applied automatically.

### Online Search

In the search window, switch to **Online**, select languages, and click **Search**. Exact video matches appear first, followed by title-based results. A subtitle is downloaded only when you assign the selected result to S1 or S2.

Each movie gets a dedicated persistent folder under:

```text
~/Library/Application Support/KinoXPlayer/Downloaded Subtitles/v1/<Movie title — short code>/
```

The stable short code separates different movies with identical titles. The system **Load S1/S2** dialog opens in the current movie's folder. The app remembers subtitle assignments and restores S1/S2 when the movie is reopened. Legacy files from version 1.4 are copied from the shared download root into the appropriate movie folder when used.

Click **Movie Folder** to open the folder in Finder. **Show in Finder** and **Save a Copy…** are available for the selected result and in the **File** menu on each S1/S2 card.

The online catalog requires an OpenSubtitles.com application API key. For a personal copy, create a consumer named `KinoXPlayer` under [API Consumers](https://www.opensubtitles.com/en/consumers), then paste its key into the app's secure field. The key and user session are stored in macOS Keychain; the OpenSubtitles password is not saved. Download allowances depend on your account and are reported by the service.

During online search, OpenSubtitles receives your IP address, app version, selected languages, entered title, file size, and a 16-character hash calculated from the beginning and end of the video. The full file path, video, and audio are not uploaded. Local search works without an internet connection or API key.

Locally built apps use an ad-hoc signature. This supports local use but does not replace Developer ID signing and notarization for public distribution. If macOS blocks a downloaded copy, use the system's **Open** action or review the relevant option in **System Settings → Privacy & Security**.

## Building in Xcode

You need Xcode with the macOS SDK and command-line tools installed. The project downloads a pinned compatible version of its Swift tokenization dependency during the first build.

1. Open `native/KinoXPlayer.xcodeproj` in Xcode.
2. Select the **KinoXPlayer** scheme and **My Mac** destination.
3. Press `Command–R` to build and run.
4. For a manual Release build, choose **Product → Archive** or change the scheme's build configuration to **Release**.

**Sign to Run Locally** is sufficient for development. A developer account and Developer ID certificate are not required.

## Building with the Script

From the repository root, run:

```sh
./native/Scripts/build-release.sh
```

Or, from the `native` directory:

```sh
./Scripts/build-release.sh
```

The script:

- checks for `KinoXPlayer.xcodeproj` and `xcodebuild`;
- builds the **KinoXPlayer** scheme in the **Release** configuration;
- uses a temporary directory for intermediate files;
- applies and verifies an ad-hoc signature without requesting Developer ID credentials;
- places the result in `native/dist/KinoXPlayer.app`.

After a successful build, launch the app with:

```sh
open native/dist/KinoXPlayer.app
```

If the expected project is missing or renamed, the script exits with an error without changing the contents of `dist`.

## Supported Formats

Playback uses the system AVKit/AVFoundation frameworks, so compatibility depends on the macOS version, container, and video/audio codecs. The most reliable options are:

- `MP4`, `M4V`, and `MOV` video containers;
- system-supported H.264 and HEVC/H.265 video;
- AAC and other audio formats supported by AVFoundation;
- external `SRT` and `WebVTT` (`.vtt`) subtitles.

Advanced ASS/SSA effects, karaoke, and complex subtitle typography are not supported. Each track's appearance is configured through the app.

## AVKit Limitations

- `MKV` is not reliably supported by system AVKit. A file may fail to open even when its video uses H.264 or HEVC.
- `AVI`, `WebM`, and uncommon audio/video codecs may also fail to play. The app does not transcode these files automatically.
- Both external subtitle tracks use the app's own overlay and work in windowed and fullscreen modes.
- System Picture in Picture generally shows only the AVKit video layer. Custom dual subtitles may be absent.
- Ad-hoc signing is intended for local use. Distribution without Gatekeeper warnings requires Developer ID signing and notarization, which the build script does not perform.
