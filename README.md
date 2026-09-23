# Owenisas Music

A local-first iOS and iPadOS music library and player built with SwiftUI. Import your own audio, keep the library on-device, and manage playback without handing your collection to a streaming service.

[![Platform](https://img.shields.io/badge/platform-iOS%20%2F%20iPadOS-111827?logo=apple)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift)](https://www.swift.org/)
[![License](https://img.shields.io/badge/license-personal--use-lightgrey)](#license)

## What it does

- Imports local audio into `Documents/Songs/` and synchronizes the library with SwiftData.
- Plays local MP3, M4A, AAC, WAV, and FLAC files with queue management, shuffle, repeat, crossfade, and playback-speed controls.
- Restores playback sessions and keeps recently played, most played, liked-song, playlist, and listening-history state on the device.
- Provides search, browse, album/artist views, playlist management, library backup, and Now Playing controls.
- Optional iCloud sync of songs and library data across your devices (a mirror of `Documents/Songs` in the app's iCloud Drive folder).
- Home Screen / Lock Screen Now Playing widgets and a Control Center play/pause control.
- Apple Watch app: control the iPhone, browse and play the library, and download playlists to the watch for offline listening.
- Share extension: save audio files from other apps (personal build also accepts YouTube links).
- Keeps the App Store build free of accounts, tracking, analytics, advertising, and any remote media-download service.

## Screenshots and demo

The app is designed for a personal local-library workflow. Add screenshots or a short capture under `docs/media/` before publishing a public product showcase; avoid committing downloaded songs, cookies, or private library data.

## Architecture

```text
iOS / iPadOS SwiftUI app
  ├─ SwiftData library and playlist models
  ├─ Documents/Songs/ local audio storage
  ├─ AVAudioPlayer + MediaPlayer remote controls
  └─ local backup/export through Apple's system file picker
```

The App Store target is local-only. Historical/private backend tooling remains outside the shipping target and is not part of the App Store binary.

## Build and test

Requirements:

- Xcode with the iOS 18.4 SDK or newer
- A simulator or iPhone/iPad running a compatible iOS version

```bash
xcodebuild test \
  -project "Owenisas Music.xcodeproj" \
  -scheme "Owenisas Music" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath /tmp/owenisas-music-derived-data \
  CODE_SIGNING_ALLOWED=NO
```

Open `Owenisas Music.xcodeproj` for interactive development. The repository also contains UI tests and focused SwiftData/queue/library-backup tests.

Tests that hit live YouTube are skipped by default. Opt in with `TEST_RUNNER_OWENISAS_LIVE_TESTS=1`.

### Two builds from one target

| Build | How | Contents |
|---|---|---|
| Personal (Debug / TestFlight internal) | Xcode run, `fastlane beta` | Everything, including the Download tab (`#if !APP_STORE`) |
| App Store | `fastlane release`, EAS `production` | Import-only; built with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=APP_STORE`, and the EAS step fails if any YouTube code or resource is bundled |

App Store Review Guideline 5.2.3 rejects apps that download media from YouTube and similar sources, so the downloader must never reach an App Store submission.

## Privacy and scope

The App Store build keeps local audio and library state on-device. See [PRIVACY.md](PRIVACY.md) and [SUPPORT.md](SUPPORT.md).

## License

No open-source license has been declared yet. Until one is added, the source should be treated as **all rights reserved / personal use** rather than assumed to be permissively licensed.
