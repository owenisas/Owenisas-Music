# Owenisas Music iOS 27 and watchOS 27 feature research

Last updated: 2026-09-29

## Recommendation

Prioritize named-song/playlist Siri playback, reliable system Now Playing including Dynamic Island, and a Watch Smart Stack entry point. Add a sleep-timer Live Activity and playlist/queue interaction polish after those. Music analysis is a useful differentiator, but it is a separate feature with analysis cost and UX decisions, not a release-blocking compatibility fix.

## Implementation verification

Local source now includes library-aware Siri/Shortcuts entities/actions, an iOS 27 AudioSearch resolver, configurable iPhone playlist widgets, additional playback controls, an embedded Watch widget extension, and the sleep-timer Live Activity. The research baseline sections below describe the source before implementation; they are not current feature inventories.

Parent-verified final unit result: **338 passed, 0 failed, 2 skipped, 340 logical tests**, including all 19 Siri tests, with no source exclusions (`build/timer-qa/full-green.xcresult`). Existing AVAudioSession main-thread performance warnings remain. The test shutdown stall was traced to Xcode simulator diagnostics collection, not lingering playback; use `-collect-test-diagnostics never` for these simulator runs.

Parent-verified timer UI test: **1 passed**, clean exit and no runtime warnings (`build/timer-qa/deeplink-ui-green.xcresult`). It covers cold launch with no song, opening the actual sleep-timer sheet, setting 15 minutes, native compact Dynamic Island presence, tapping back to the timer and cancelling. The SpringBoard screenshot `build/timer-qa/native-system-island-attempt.png` visibly shows the mint moon and 14:54 countdown. Final shared-view renders under `build/island-renders/` have no yellow unsupported-render placeholder; these are frozen-date SwiftUI renders, not native Lock Screen/expanded Island captures.

Watch extension embedding and its generated URL scheme were read back from the integrated simulator app bundle. Seven Python integration-contract tests pass. Signed App Group enforcement and paired-device interactions are unverified.

App Schema adoption, Spotlight indexing, conversational/locked-device Siri routing, physical-device Live Activity behavior, native expanded Island/Lock Screen capture, and a mutually exclusive iOS 27 NowPlaying-framework migration are not verified or implemented by these changes. Existing MediaPlayer publishing remains in use. Performance improvements and benchmark boundaries are documented in `docs/performance.md`.

All changes remain local, uncommitted and absent from the existing uploaded TestFlight build. No signing, upload, review submission or tester-access change occurred.

## Current source, not uploaded-binary guarantees

- `Owenisas Music/MusicPlayerManager.swift:943` publishes title, artist, album, elapsed time, duration, rate and artwork through `MPNowPlayingInfoCenter`.
- `Owenisas Music/MusicPlayerManager.swift:982` handles play, pause, toggle, next, previous and seek through `MPRemoteCommandCenter`.
- `OwenisasWatch/WatchLocalPlayer.swift:229` registers Watch remote commands and publishes local Watch playback metadata.
- `Shared/PlaybackIntents.swift:31` defines four `AudioPlaybackIntent` controls for toggle, next, previous and favorite. This is a useful base but is not a complete named-content Siri integration.
- `OwenisasWidget/NowPlayingWidget.swift:59` uses `StaticConfiguration` for small/medium Home Screen and accessory Lock Screen widgets. It has no playlist parameter.
- `OwenisasWidget/PlayPauseControl.swift:8` defines a Control Center playback control.
- No matches for `ActivityKit`, `DynamicIsland`, `AppShortcutsProvider`, `INPlayMedia`, `AssistantSchema` or a new NowPlaying import were found in the Swift source search.
- The Watch app already separates phone controls from offline Watch playback. Do not let new intents silently target the wrong player.
- Project deployment targets are iOS 18.4 and watchOS 10.0. Keep them unless a separate product decision changes compatibility.

## Feature priorities

| Priority | Feature | User benefit | Existing foundation | Proposed scope |
|---|---|---|---|---|
| First | Siri songs and playlists | Say "Play my Running playlist in Owenisas Music", find a song by artist/title, like the current song, set a sleep timer | Playback intents and local library | Stable song/playlist entities, queries, explicit play and pause, App Shortcuts; OS 27 Media Intents and schema adoption |
| First | Native Dynamic Island and system playback | Correct artwork, track progress and controls outside the app | Existing MediaPlayer publishing | First verify current native presentation; then adopt the OS 27 NowPlaying framework behind a mutually exclusive adapter |
| First | Watch Smart Stack and complications | Reach phone controls or an offline playlist without browsing the app | WatchConnectivity and separate phone/local Watch players | Watch-target widgets with explicit destination and relevance; refresh through supported WatchConnectivity integration |
| Next | Sleep-timer Live Activity | See time remaining, extend or cancel without reopening the player | Player has sleep-timer state | ActivityKit countdown with compact, expanded, landscape-width and Watch-small layouts |
| Next | Better playlist and queue editing | Reorder without entering a separate edit mode; swipe to enqueue, like or remove | Existing queue and playlist screens | OS 27 SwiftUI reordering and swipe APIs with older-OS fallback; preserve duplicate queue entries and persistent order |
| Next | Personalized widgets and system controls | Pin a playlist, Liked Songs or a useful action | Static widget and play/pause control | AppIntentConfiguration, deep links, additional controls, clear/tinted appearance QA |
| Later | On-device music analysis | BPM/key badges, energy-oriented sorting and playlists, loudness information | Local audio files | OS 27 MusicUnderstanding analysis cache and optional analysis UX; no cloud upload required for this feature |

Priority is a product recommendation, not a measured effort estimate.

## 1. Dynamic Island: native playback versus custom UI

Apple's system Now Playing UI appears in Dynamic Island. An ActivityKit implementation is not required solely to show the currently playing song. Existing source already has the older MediaPlayer metadata/command integration needed for system playback; actual presentation and behavior still require physical-device verification. [1][2]

The new NowPlaying framework is documented for iOS 27 and watchOS 27. Use an observable `MediaSessionRepresentable` model and a `MediaSession` to publish local playback. `MusicContent` describes the current track. The framework observes changes and publishes them to system interfaces. [1]

Apple explicitly warns that combining this framework with `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for local playback produces undefined behavior. Implementation must select one publishing/command backend per OS, including all current timer-driven metadata writes and command registrations. Keep the old backend below 27. [1]

The app does not control the system Now Playing layout. Use a custom Live Activity only for genuinely extra ongoing information, such as a sleep timer or a user-started audio import task. Avoid duplicating the same playback card. This is a design recommendation, not a statement that Apple prohibits every custom music activity.

WWDC26 adds a landscape Dynamic Island presentation with limited-width adaptation. A custom activity should simplify compact content when width is limited and provide the small activity family for Apple Watch. Button interactions use App Intents. [3]

Acceptance: artwork/metadata update on track transitions and crossfades; pause progress freezes; seeks publish correctly; route changes/interruption recovery work; commands do not execute twice; ending playback clears stale state; activity ends on timer cancellation and restoration does not resurrect an expired timer.

## 2. Siri: a library-aware integration

Existing toggle/skip/favorite intents can power widgets and Shortcuts actions, but they do not provide a queryable song or playlist catalog or prove conversational Siri support.

Start with stable SongEntity and PlaylistEntity models, title/artist lookup, suggested entities, explicit play and pause actions, and an AppShortcutsProvider for older supported systems. Prefer explicit actions over toggle when a voice command says "pause" or "play". Define missing-file, empty-playlist and ambiguous-title responses instead of returning success with no playback.

For OS 27, Apple's Media Intents framework introduces `AudioSearch`, delivered through App Intents. It supports structured requests and uses app-provided queries to resolve matching content. Apple's CosmoTunes sample demonstrates songs/playlists, unspecified playback requests and named-playlist playback. [4][5]

Adopt appropriate App Schemas so Siri understands content and actions. Index suitable entities in Spotlight; support search without indexing everything when that better fits the library. View annotations and `NSUserActivity.appEntityIdentifier` associate visible content with entities. NowPlaying content can carry `appEntityIdentifiers`, ordered from most specific to least specific. This allows requests referring to the playing or visible song. [5][6]

New `SyncableEntity` declares cross-device stable identity. Align it with the library's canonical sync identity, not a local SwiftData persistent identifier or device-specific file path. IDs alone do not transfer missing audio, grant access, or route phone playback to an offline Watch player. [7]

Example target requests, not promises already verified:
- "Play my Running playlist in Owenisas Music."
- "Play [song] by [artist] in Owenisas Music."
- "Like this song."
- "Add this song to my Favorites playlist."
- "Stop playing in 30 minutes."

A request like "play energetic music" requires meaningful searchable data or app-side matching. App Schemas do not magically classify arbitrary imported files. Siri/Apple Intelligence availability also depends on device, language, region and rollout. Keep explicit Shortcuts/widget actions as a fallback.

Acceptance: deterministic entity/query tests, AppIntentsTesting where available, Shortcuts execution, Spotlight index/delete consistency, then physical-device Siri tests. Cover a cold app, a locked device, duplicate titles, empty library, missing audio, expired timer and phone-versus-Watch destination. [6][8]

## 3. Watch Smart Stack and complications

The inspected Watch Swift files contain no WidgetKit widget definition. Phone widgets do not substitute for a Watch-specific offline-library widget.

Build a compact view with track title/artwork, phone-versus-Watch indicator and play/pause. Offer an offline playlist shortcut with a visible availability indicator. Relevance should reflect a real session or chosen routine; do not keep the widget permanently competing for the top position.

Smart Stack relevance widgets and controls were introduced in watchOS 26, not 27. OS 27 adds WatchConnectivity-based widget refresh support according to Apple's watchOS group lab. It also improves widget performance and reliability. [9][10]

Do not use widget refresh as an every-second progress mechanism. Apple's lab explains that refresh budgets depend on placement and actual engagement. Use timestamp-based drawing for progress and reload for meaningful state changes. Exact new WatchConnectivity API selection still needs SDK/type-level lookup before implementation. [9]

The new watchOS 27 single-tap gesture is a system Smart Stack interaction. It is not evidence that an app can arbitrarily capture that gesture or control the system app grid. [11]

Acceptance: paired-device refresh, phone unreachable state, independent offline playback, correct player routing, complications at supported sizes, Smart Stack actions, no stale track after playback stops, VoiceOver and Always On presentation.

## 4. UI polish that maps to actual music tasks

WWDC26 SwiftUI adds reorderable containers for lists and grids, including watchOS; swipe actions on arbitrary views; toolbar visibility priorities, overflow grouping, pinned placement and minimize-on-scroll behavior. These can improve queue editing, playlist ordering and compact navigation. [12]

Use higher visibility for Search/Add and deliberate overflow for rarely used actions. Keep the mini-player reachable while scrolling. Updated materials and typography should support readable album artwork and lyrics; adopting every glass effect is not a product goal.

WidgetKit supports AppIntentConfiguration for personalized content. New large portrait widget support is described in WWDC26, but that is lower priority than a useful playlist selector and correct clear/tinted rendering. Small/medium and Lock Screen widgets already exist in this source. [13]

Watch reorder UX and song-row swipe actions deserve a small prototype, not a wholesale rewrite. Avoid introducing a new library identity or ordering scheme while data-safety fixes are landing.

## 5. On-device music analysis

MusicUnderstanding is documented for the 27 releases, including iOS and watchOS. It analyzes key, rhythm, structure, pace, instrument activity and loudness. It accepts a file-backed AVAsset or an audio buffer sequence; results can be aggregated or delivered incrementally. [14]

Best initial application: an optional local analysis of imported audio with BPM/key display and a cached result. Energy-oriented playlist building is a follow-up product interpretation of rhythm/pace/activity results, not an Apple-provided mood label. Loudness results could inform a later volume-leveling feature; analysis alone does not normalize playback.

Analyze primarily on iPhone, cache against file content/version, and make cancellation/battery behavior explicit. Framework availability on Watch is not proof that processing a large library there is cheap. Lyrics generation and speech transcription are not promised capabilities of this framework.

## Implementation and release separation

1. Finish the existing data-safety release audit and current candidate verification.
2. Implement named-content intents and test native Dynamic Island behavior using the current publisher.
3. Add OS 27 NowPlaying/MediaIntents behind availability checks with lower-OS fallbacks.
4. Add Watch widgets, personalized controls and sleep-timer Live Activity.
5. Prototype queue/list interaction updates, then decide whether music analysis belongs in the next release.

A 27 SDK is required to compile new 27 APIs. Availability checks preserve old runtime support but do not make an older SDK understand the new symbols. Verify a non-beta cloud Xcode 27 build image before claiming an App Store release can contain these additions. Documentation availability is not build-toolchain verification.

The initial research pass changed documentation only. Subsequent local implementation and verification are summarized in §Implementation verification above.

## Sources and evidence boundaries

Official Apple sources were retrieved through the shared research pool, with direct Apple DocC JSON readback for framework platform availability. Indexed search excerpts helped locate WWDC sessions. No framework was exercised or Siri conversation tested in this pass. The watchOS guide extraction was incomplete; Watch recommendations rely on the group lab and separate official sessions. Python HTTPS verification failed in one direct probe; system curl succeeded without disabling certificate verification. The WidgetKit updates page still listed June 2025 changes, so 27 claims use WWDC26 rather than assuming that changelog is complete.

1. [Now Playing documentation](https://developer.apple.com/documentation/nowplaying), availability and warning against mixed publishing backends.
2. [Meet the Now Playing framework, WWDC26](https://developer.apple.com/videos/play/wwdc2026/312/), native Dynamic Island and system playback.
3. [Live Activities essentials, WWDC26](https://developer.apple.com/videos/play/wwdc2026/223/), landscape presentation and Watch sizing.
4. [Media Intents documentation](https://developer.apple.com/documentation/MediaIntents), audio search through App Intents. Platform metadata verified through Apple's DocC JSON endpoint.
5. [Explore advanced App Intents features for Siri and Apple Intelligence, WWDC26](https://developer.apple.com/videos/play/wwdc2026/343/), CosmoTunes, song/playlist search and contextual annotations.
6. [Build intelligent Siri experiences with App Schemas, WWDC26](https://developer.apple.com/videos/play/wwdc2026/240/), entity/schema model and progressive testing.
7. [App Intents updates](https://developer.apple.com/documentation/updates/appintents), June 2026 stable entity IDs, RelevantEntities and execution targets.
8. [Validate your App Intents adoption with AppIntentsTesting, WWDC26](https://developer.apple.com/videos/play/wwdc2026/295/), testing entry point identified in Apple's iOS guide; full session not extracted here.
9. [watchOS Group Lab, WWDC26](https://developer.apple.com/videos/play/wwdc2026/8014/), WatchConnectivity widget refresh and budget guidance.
10. [What's new in widgets, WWDC25](https://developer.apple.com/videos/play/wwdc2025/278/), existing watchOS 26 relevance and controls.
11. [watchOS 27 product overview](https://www.apple.com/os/watchos/), single-tap Smart Stack gesture and Siri rollout context.
12. [What's new in SwiftUI, WWDC26](https://developer.apple.com/videos/play/wwdc2026/269/), transcript and code for reorder, swipe and toolbar changes.
13. [WidgetKit foundations, WWDC26](https://developer.apple.com/videos/play/wwdc2026/277/), personalization, appearance and portrait family.
14. [Meet the Music Understanding framework, WWDC26](https://developer.apple.com/videos/play/wwdc2026/253/) and [framework docs](https://developer.apple.com/documentation/musicunderstanding), analysis dimensions and local input handling.
15. [Apple's iOS 27 developer guide](https://developer.apple.com/wwdc26/guides/ios/) and [watchOS 27 guide](https://developer.apple.com/wwdc26/guides/watchos/), framework discovery.
