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
- Fetches optional synced lyrics through LRCLIB and can use the companion backend to prepare audio from supported YouTube video IDs.

## Screenshots and demo

The app is designed for a personal local-library workflow. Add screenshots or a short capture under `docs/media/` before publishing a public product showcase; avoid committing downloaded songs, cookies, or private library data.

## Architecture

```text
iOS / iPadOS SwiftUI app
  ├─ SwiftData library and playlist models
  ├─ Documents/Songs/ local audio storage
  ├─ AVAudioPlayer + MediaPlayer remote controls
  ├─ LRCLIB lyrics lookup (optional)
  └─ optional Flask + yt-dlp backend for audio preparation
```

The backend is not required for local playback. It exposes narrow endpoints for version checks, audio preparation, and lyrics conversion; deploy it separately and provide credentials/cookies only through private runtime configuration.

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

## Privacy and scope

Owenisas Music is a personal-use project, not an App Store distribution. Local audio and library state are intended to remain on-device. If the optional backend is enabled, review its deployment configuration and do not commit YouTube cookies, downloaded media, runtime logs, or private tokens.

## License

No open-source license has been declared yet. Until one is added, the source should be treated as **all rights reserved / personal use** rather than assumed to be permissively licensed.
