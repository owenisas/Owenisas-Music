# iPhone YouTube audio download

**Last updated: 2026-09-22**

How Owenisas Music fetches YouTube audio **on a physical iPhone**, no Mac/LAN
proxy. This is the on-device recipe that actually landed files in Library
after `Audio Error: YouTube might be blocking the request`.

Related: `youtube-coverage-2026-08-28.md` (client chain / coverage),
`youtube-tier2-feasibility.md` (kids/WEB_EMBEDDED — not this bug).

## Status (verified on device)

| Item | State |
|---|---|
| App Store binary | import-only; 0 YouTube strings. Do not upload without sign-off. |
| Debug / USB install | YouTube downloader **on**. Last working install: USB Debug to iPhone 13 mini `<iphone-udid>` |
| Mainstream audio on phone | **Works** after the 2026-08-29 chunked-Range fix (Steins;Gate `Ttq6DJfA-So` downloaded) |
| Kids / Baby Shark | Still not a client bug — live-control yt-dlp first (see tier2 doc) |
| Share extension + background downloads (2026-09-22) | Simulator: Safari share → extension → app opened → download finished in the background. `BGContinuedProcessingTask` and open-from-extension not yet run on the phone. |
| Downloader hardening (2026-09-22) | Verified in simulator: `jNQXAC9IVRw` single download, captions saved, playlist dialog (478-song playlist parsed), cancel, store-loss recovery from `meta.json`. Not yet re-run on the phone. |

## The method (do this before rewriting the client)

Phone logs beat Mac/sim guesses. YouTube googlevideo URLs that **HTTP 200
from this Mac in 0.1s** still sat at **0 bytes for minutes** in
`URLSessionDownloadTask` on the iPhone.

1. Copy the on-device log (app Documents, survives reinstall of the same bundle):
   ```
   xcrun devicectl device copy from --device <iphone-udid> \
     --domain-type appDataContainer --domain-identifier com.Owenisas-Music \
     --source Documents/download-debug.log \
     --destination /tmp/owen-phone-logs/download-debug.log
   ```
2. Read the **tail**. `resolveAudio succeeded via VISIONOS` + `Starting download [audio]` + no byte count = fetch-path bug, not innertube.
3. Discriminate **probe vs full download**. If a 1 KB `Range: bytes=0-1023` `dataTask` works and `downloadTask` of the same URL does not, do not chase PO tokens / n-sig / player.js.
4. Always run a live control on a second video (and yt-dlp) before treating kids-style 403 as “our solver is wrong”.

`debugLog` writes `NSLog("OWENISAS_DOWNLOAD: …")` **and** appends
`Documents/download-debug.log`. Syslog needs root; the file copy does not.

## What the phone log actually showed (2026-08-29)

Steins;Gate OST `Ttq6DJfA-So` after the timeout-only build:

```
20:55:51  resolveAudio succeeded via VISIONOS
20:55:51  Starting download [audio] videoplayback
20:56:03  Audio download stalled (0 bytes in 12s), cancelling
20:56:03  Show error [Audio Error]: YouTube might be blocking the request.
```

City Ruins `LC5HsZt4oNc` on the older 180s ladder burned ~17 minutes retrying
the **same URL** five times, then the same error.

Cover JPEGs downloaded instantly. Innertube was fine. The googlevideo
**audio** GET was the only stall.

Same URLs from this Mac (Safari UA, with or without `Origin` /
`Accept-Encoding`): HTTP 200 / 206 in <2s. The Mac is not the phone.

## Root cause (on-device)

Two different HTTP clients were in play:

| | Resolve probe (`YouTubeClient.streamIsFetchable`) | Full audio (`DownloadView.download`) |
|---|---|---|
| Session | ephemeral, no cookies | ephemeral, no cookies |
| Task | `dataTask` / `data(for:)` | `URLSessionDownloadTask` |
| UA | Safari (`watchUA`) | iOS YouTube app `com.google.ios.youtube/20.10.4` |
| Extra headers | `Range: bytes=0-1023` | `Origin: https://www.youtube.com`, `Accept-Encoding: gzip` |
| Result on iPhone | **bytes arrive** | **0 bytes until cancel** |

VISIONOS mints a plain `url` (no `n`, no `signatureCipher`) bound to the
Safari-like client. Fetching that URL with the iOS YouTube app UA plus
`downloadTask` never delivered a first byte on device.

Also wrong, and they made “forever” out of a dead fetch:

- `timeoutIntervalForResource = 3600` and `waitsForConnectivity = true`
- Retrying the **same** stalled/403 URL 3–5 times (180s × 5 ≈ 17 min)
- `bestAudioURL` took the **first** mp4 (itag 139 @ ~50 kbps) instead of
  highest bitrate (itag 140)
- A blanket **500 KB** “too small” floor hid short clips from Library and
  refused playback even when the file existed

## Working on-device recipe (what shipped)

Code: `YouTubeClient.swift` + `DownloadView.swift`, `#if !APP_STORE` only.

**Resolve (Tier 1, no JS):**

1. GET `https://www.youtube.com/watch?v=<id>&hl=en` (Safari UA, cookie jar)
2. Pull `visitorData` from the page (~520 chars)
3. POST `youtubei/v1/player` with `X-Goog-Visitor-Id`, client chain
   **VISIONOS → IOS** (TVHTML5_SIMPLY_EMBEDDED_PLAYER dropped 2026-09-22:
   HTTP 404 for every video)
4. Pick audio by **bitrate descending** among AAC only: `audio/mp4` **and**
   an `mp4a` codec (ec-3/ac-3 also ship as audio/mp4), direct `url` only (no
   solver, so signatureCipher-only formats are skipped), default audio track
   and non-DRC first (itag 140, not 139)
5. **Probe** the URL: ephemeral session, Safari UA, `Range: bytes=0-1023`,
   6s timeout. HTTP 2xx with body → use it. Else next client.

**Fetch audio (the part that was broken):**

- Same cookie-free ephemeral session as the probe
- Safari UA (must match the client that minted the URL)
- **No** `Origin`, **no** `Accept-Encoding`
- **No** `URLSessionDownloadTask`
- Sequential `Range` GETs via `data(for:)`: first request 64 KB (proves
  bytes flow), then 512 KB chunks, written to a temp `.m4a`
- Progress from `Content-Range` total; a 206 must start at the requested
  offset. HTTP 200 is accepted only at offset 0; a 200 later means the
  server ignored Range, so the file is truncated and the body written whole
- 403/401 → fail that URL immediately (do not retry it)
- Stall: 0 bytes on the first chunk after 12 s → fail (not retried). Once
  bytes flow, each request gets 15 s idle / 45 s wall
- Mid-stream network error or 5xx/429 → retry **once** from the current byte
  offset (timeouts halve the chunk size, min 128 KB); at most 3 retries per
  file. Offline on the first chunk fails immediately
- Errors are typed (`AudioDownloadError`) and shown as specific messages:
  blocked (403), stalled, timed out, offline, interrupted in background,
  WebM/Opus, too small. Resolve failures surface YouTube's own reason
  ("YouTube says: This video is unavailable"); the old get_video_info /
  unsigned-cipher fallback chain is deleted

Covers and captions are small single `data(for:)` requests on the same cookie-free session.

**Playable container (2026-08-29):** AVAudioPlayer cannot play WebM/Opus. A fallback
to itag 251 saved Opus as `.m4a`; Library showed a song that auto-skipped on
play (looked “empty”). Only accept `audio/mp4` (AAC). Reject EBML/WebM
headers on save. “Already exists” only if the file is actually playable, so
re-download replaces the bad copy. Proven: `Ttq6DJfA-So.m4a` was WebM
(`1a45 dfa3`), duration N/A for AVAudioPlayer; AAC City Ruins `ftyp dash` played.

## Downloader behaviour (2026-09-22)

Code: `DownloadView.swift` (UI + pipeline + pure helpers), `YouTubeClient.swift`,
`LyricsParser.swift`, `DataManager.swift`. Unit tests in `Owenisas MusicTests/`
(`DownloaderLogicTests`, `ChunkedAudioDownloaderTests` with a URLProtocol stub,
`LyricsPipelineTests`, `SongFolderMetadataTests`).

- **Links:** `watch?v=…&list=…` asks "Just this song" / "Whole playlist (N)".
  `list=RD…` (radio mixes, `RDMM…`, `RDAMVM…`) download only the shared song,
  no dialog. `/playlist?list=` downloads the playlist.
- **Cancel** stops the job (tasks, URLSession requests, temp files, background
  task). A cancelled playlist keeps saved tracks and reports "Cancelled after
  N of M". Retry reuses the kept link.
- **Playlist pages changed (seen 2026-09-22):** items are `lockupViewModel`
  (`contentId`, `metadata.lockupMetadataViewModel.title.content`) followed by
  `continuationItemViewModel`; there is no `playlistVideoRenderer`. The first
  `ytcfg.set(` on the page is not JSON, so `INNERTUBE_CONTEXT` must be taken
  from the call that has it, and the browse `X-Youtube-Client-Version` header
  must match that context (a 2024 version got HTTP 400). Name comes from
  `metadata.playlistMetadataRenderer.title`.
- **Playlist bookkeeping:** progress = (index + track fraction) / count, never
  backwards; unresolvable tracks count as failed with their titles; the
  auto-created playlist gets songs in playlist order (duplicates by their real
  library id), recorded in `PlaylistData.songOrder`.
- **meta.json** (`title`, `artist`, `videoId`, `duration`, `source`) is written
  into every downloaded song folder. Library sync reads it for new rows and to
  repair placeholder rows, so a lost SwiftData store no longer shows songs as
  their video ID + "Unknown Artist". Folders without it still use
  "Artist - Title" parsing.
- **Library refresh:** after a save only that folder is synced
  (`syncSingleSong`, which now fetches just the rows that could be that song);
  no full library scan per track.
- **Lyrics:** YouTube captions come from the player response's
  `captionTracks` (uploaded beats auto-generated, `exp=xpe` URLs skipped),
  saving the original language + English as `{id}.{lang}.vtt`. LRCLIB lyrics
  (`{id}.lyrics.vtt`) are looked up with a cleaned title/artist (VEVO/Topic,
  "(Official Video)", "ft." stripped) via get, field search, then free-text
  search, and a hit is only used when the normalized title matches and the
  length is within 5 s. Re-downloading a song that has no lyric files fetches
  lyrics only. `LyricsFetcher.fetchMissingLyrics(for:)` does the same for any
  library song. The parser tolerates cue settings, whitespace-only lines,
  stanza breaks and rolling auto-captions.
- **Debug log:** hidden behind "Show details"; `Documents/download-debug.log`
  rotates to `download-debug.1.log` at ~1 MB. No cookies, headers or stream
  URLs are logged (host only).

## Share to Owenisas Music + background downloads (2026-09-22)

Code: `OwenisasShare/` (extension), `Shared/SharedInbox.swift`,
`Shared/YouTubeLinkClassifier.swift`, `Owenisas Music/Integrations/IncomingShares.swift`,
`DownloadView.swift` (`DownloadRequestCenter`, `BackgroundDownloadActivity`).
Tests: `SharedInboxTests`, `BackgroundDownloadTests`.

- **Hand-off:** the extension never touches the network. It appends
  `{id, link, choice}` to `AppGroup/Inbox/links.json` (NSFileCoordinator
  read-modify-write + atomic replace; same link+choice while queued is not
  added twice) or copies audio to `Inbox/Audio/<uuid>/<name>` (staged in
  `.incoming-<uuid>`, then renamed). The app drains at launch and on every
  `didBecomeActive`: audio goes through `DataManager.importAudioFiles`, links
  go to the Download tab one at a time. A link leaves the inbox only when its
  job ends (finished, failed or cancelled), so a download killed with the app
  resumes on the next launch.
- **Opening the app from the extension:** `NSExtensionContext.open` does not
  work for share extensions. The extension walks the responder chain to the
  `UIApplication` and calls `open(_:options:completionHandler:)` (the old
  `openURL:` selector is a no-op since iOS 18). Worked in the iOS 26.5
  simulator; if it fails or nothing answers in 3 s the sheet says "Added — it
  starts next time you open Owenisas Music" (plus a local notification if
  notifications are already allowed). Personal builds only; the App Store
  extension accepts audio only and just queues it.
- **URLs:** `owenisas://download` drains; `owenisas://download?url=<link>[&choice=song|playlist]`
  queues a link (Shortcuts). `simctl openurl` shows an "Open in…?" prompt.
- **Background (iOS 26+):** each session submits a `BGContinuedProcessingTask`
  (`com.Owenisas-Music.download.<uuid>`, strategy `.fail`, progress 1000 units
  per queued job, title/subtitle updated as tracks finish). Apple DTS
  (forums thread 799126): a handler registered for the wildcard itself is never
  matched and the submit crashes with "No launch handler registered", so each
  session registers its own full identifier right before submitting (each
  identifier once; a second registration kills the app). The work starts
  immediately either way; the task only adds background time. Expiration
  (system, or Stop in the system UI) = Cancel: saved tracks stay, queued links
  wait for the foreground. Until the task is running, and on iOS < 26 or when
  submission fails, the old `beginBackgroundTask` grant is held.
- **Simulator:** `submit` throws BGTaskScheduler error 1 (unavailable), so only
  the ~30 s legacy grant is exercised there; a backgrounded download of
  `jNQXAC9IVRw` finished under it (app process heavily throttled: a caption
  request took ~28 s). On-device continued processing is not yet verified.

**USB install** (App Store IPA cannot sideload — distribution profile has no
device UDID):

```
UDID=<iphone-udid>   # xcodebuild id; CoreDevice lists a different id
xcodebuild -scheme "Owenisas Music" -configuration Debug \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath /tmp/owen-build-phone \
  -allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=3LHSL95J9H build
xcrun devicectl device install app --device "$UDID" \
  "/tmp/owen-build-phone/Build/Products/Debug-iphoneos/Owenisas Music.app"
```

Phone must be unlocked + Developer Mode. After install, if a spinner from
the previous binary is still up, force-quit so you are not watching a dead
`downloadTask`.

## UI bug that looked like “download page kicks me back”

`TabView(selection:)` with a Download tab that had `.tabItem` but **no
`.tag`**. `AppTab` had no `download` case, so SwiftUI snapped selection
back to Home. Fix: `AppTab.download` + `.tag(AppTab.download)` inside
`#if !APP_STORE`.

## What not to do next time

- Do not treat Mac HTTP 200 as proof the iPhone fetch works.
- Do not rebuild WEB_EMBEDDED / JS solver because a mainstream OST 403s or
  stalls on device — check `download-debug.log` first.
- Do not retry the same googlevideo URL on 403 or 0-byte stall.
- Do not set `timeoutIntervalForResource` to an hour to “let HLS finish”.
- Do not use `URLSession.shared` (cookie jar) for googlevideo — 403.
- Live-control yt-dlp **right now** before debugging kids/age-restricted.
- Do not fall back to legacy endpoints when the resolver fails: it hid the
  real reason behind minutes of dead requests.
- Do not append a 200 response to bytes already written.
- Do not assume YouTube page JSON keeps its shape: check the playlist page
  renderers live when playlists return nothing.

## Device IDs (this machine)

| Name | ID | Use |
|---|---|---|
| CoreDevice / `devicectl list` | `<coredevice-id>` | list/copy |
| `xcodebuild -destination` / `devicectl install` | `<iphone-udid>` | build + install |
| Bundle | `com.Owenisas-Music` | app container |
