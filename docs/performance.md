# Owenisas Music performance

Last updated: 2026-09-29

## Implemented and measured

This pass implements two source-level optimizations. It does not certify whole-app launch latency, battery life, frame rate, or physical-device responsiveness. Source remains uncommitted and is not in the existing TestFlight binary.

### Bounded player artwork decode

`Owenisas Music/VisualizerBackground.swift`, `ImageCache.image(for:)`, now uses ImageIO downsampling during decode, capped at 2048 pixels on the longer edge. Orientation is applied during thumbnail creation. Unsupported ImageIO formats retain the previous compatibility fallback. Existing 48-point row thumbnails and cache cost accounting remain intact. Original artwork files are not rewritten.

Reproduction: generated two-color 4096×3072 JPEG, ten cache-cleared decodes on the same iPhone 18 Pro / iOS 27 simulator, Debug configuration. These are synthetic microbenchmarks, not an Instruments peak-RSS measurement.

| Measurement | Before | After |
|---|---:|---:|
| Median cold decode | 18.0908 ms | 14.1942 ms |
| Decoded CGImage buffer | 50,331,648 bytes | 12,582,912 bytes |

Decoded buffer is 75% smaller. Latest median decode is about 21.5% lower; an earlier optimized run was 13.6466 ms, demonstrating normal simulator variance. No claim about total app memory or latency follows from this alone. Artwork below the cap is not intentionally enlarged; wide/tall images retain their aspect ratio. ImageIO-incompatible fallback formats do not have the same guaranteed bound.

### One search snapshot per render

`Owenisas Music/LibrarySearchResults.swift` computes song, artist, and playlist matches once. `SearchView.searchResults` reuses that snapshot for emptiness checks, section conditions, displayed rows, and the playback queue. Previously the computed song property scanned the library separately for each access.

Matching semantics remain `localizedCaseInsensitiveContains`; ordering, duplicate song identities, unique sorted artist names, and the complete matched-song playback queue are preserved. The snapshot is not a long-lived cache, so @Query-driven metadata edits do not leave stale search results. No debounce or deliberately delayed input was introduced.

Same-process comparison: 3,000 synthetic SongData objects, seven iterations, old three song-filter accesses plus artist filtering versus one complete new snapshot. Median filtering work: **15.0455 ms → 6.1964 ms**, about **58.8% lower**. This measures result computation, not complete UI render time or keyboard-to-paint latency.

## Verification

- RED artwork test: existing decoder returned 4096 pixels, failing the 2048-pixel bound.
- GREEN artwork tests: bounded resolution/aspect ratio, cache reuse, small thumbnail/cache clearing, cold decode benchmark.
- RED search tests: missing LibrarySearchResults implementation.
- GREEN search tests: title/artist/album and playlist matching, preserved song order, empty query, metadata mutation, matched-result equivalence and benchmark.
- Focused performance run: seven tests passed.
- Broader unit run: xcresult summary **318 passed, 0 failed, 2 skipped, 320 logical tests**. Device summary reports 338 passed executions because parameterized tests add runs; these are not 338 distinct test definitions.
- `git diff --check` passed.

The performance and broader unit commands temporarily set `EXCLUDED_SOURCE_FILE_NAMES=SiriLibraryTests.swift`: the parallel Siri implementation was still introducing RED tests and could otherwise block unrelated test compilation. This is a command-only exclusion, not a project setting or deletion. Therefore this result is **not** full Siri-integrated release sign-off. No production archive, upload, paid compute, commit or push occurred.

Evidence:
- Baseline: `build/performance-derived/Logs/Test/Test-Owenisas Music-2026.09.29_21-01-49--0700.xcresult`
- Focused green: `build/performance-derived/Logs/Test/Test-Owenisas Music-2026.09.29_21-09-35--0700.xcresult`
- Broader regression: `build/performance-derived/Logs/Test/Test-Owenisas Music-2026.09.29_21-10-44--0700.xcresult`
- Console benchmark output exported into `build/artwork-baseline-diagnostics/` and `build/performance-green-diagnostics/`.

## Research and remaining boundaries

Apple's [Profile, fix, and verify: Improve app responsiveness with Instruments](https://developer.apple.com/videos/play/wwdc2026/268/) recommends separating CPU saturation, executor contention, and synchronous I/O blocking, then comparing matched runs. This supports keeping artwork decode off-main and measuring the actual changed path rather than inferring whole-app speed from a source refactor.

Apple's [Dive into lazy stacks and scrolling with SwiftUI](https://developer.apple.com/videos/play/wwdc2026/321/) explains prefetch, stable subview structure and avoiding layout-driven onAppear work. Do not mechanically replace every VStack with LazyVStack: estimated heights and state lifetime change.

Both official pages were extracted through the shared research pool. WatchConnectivity reload budgets and timestamp-based rendering remain documented in `docs/ios-watchos-features.md`.

Inspected but not modified in this performance pass:
- DataManager's synchronous filesystem scan and per-song indexing: overlaps concurrent data-safety changes; moving SwiftData models across executors or changing deletion semantics without a dedicated design is unsafe.
- Playback timer/database checkpoint frequency: overlaps concurrent playback correctness work; less frequent writes may lose resume position without an explicit lifecycle flush.
- Existing artwork loaders already run decode tasks off-main, list images already downsample, and the background gradient has no per-frame TimelineView. Do not claim those pre-existing choices as new improvements.

Physical-device Time Profiler/System Trace, cold-launch measurements, large real-library scroll hitch rate, background CPU/energy, and full integrated Siri/Watch tests remain unverified. Those need actual device profiling, not synthetic percentage extrapolation.
