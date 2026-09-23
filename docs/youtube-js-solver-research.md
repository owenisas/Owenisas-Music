# YouTube downloader JS solver — research (2026-08-27)

## Why this is needed

The `IOS 20.10.4` client works for some videos (e.g. Rick Astley) but
gets `ERROR: This video is unavailable` for most popular videos
(Despacito, Gangnam Style, Uptown Funk, etc.). YouTube added a per-video
JS challenge (`n` parameter) to their innertube endpoint in 2025. The
only way through is to solve the `n` challenge using YouTube's own
obfuscated `player.js` — a problem yt-dlp solves with the **yt-dlp-ejs**
JS engine plugin.

## What yt-dlp does (proven by source + empirical testing)

1. Default clients: `('visionos', 'web')` — `visionos` is the Apple Vision
   Pro YouTube app client, not in public docs. Apple has not gated it
   like IOS/Tv/MWEB.
2. yt-dlp fetches `player.js` (~600KB obfuscated) from
   `https://www.youtube.com/s/player/{hash}/player_es6.vflset/en_US/base.js`
3. Sends player.js + challenge string to `yt.solver.core.js` (12.6KB IIFE)
4. That core imports `meriyah@6.1.4` (JS parser, ISC) + `astring@1.9.0`
   (JS codegen, MIT), both pure JS
5. The core parses player.js, extracts the `n`-parameter and signature
   functions via AST manipulation, regenerates an executable solver, and
   runs it on the challenge to produce the `n` token
6. The `n` token goes back into the next innertube call as
   `serviceIntegrityDimensions.poToken` — YouTube then returns real audio URLs

## What this means for Owenisas Music iOS

- iOS ships JavaScriptCore (`JSContext` in Swift) — can run any JS
- yt-dlp-ejs is open source (Unlicense), npm-installable, buildable into
  a single IIFE bundle
- Total bundle: ~150KB minified (12.6KB core + ~120KB meriyah + ~20KB astring)
  — no native dependencies
- A Swift bridge can load the JS via `JSContext`, pass `input` JSON, get
  `output` JSON, parse the result, attach as `serviceIntegrityDimensions`
  to the next innertube POST

## iOS-specific constraints

- `JSContext` does NOT support ES modules, `import`, or `import()` — must
  use the IIFE build of `yt.solver.core.js` or manually inject globals
- `meriyah@6.1.4` + `astring@1.9.0` are pure ES5/ES2015 — they work in
  JavaScriptCore without modification
- The whole solver bundle is plain JS that runs in `JSContext` directly
- `JSContext` sandboxing is acceptable — the solver doesn't need DOM/Network

## App Store risk

- App Review Guidelines §5.2.3: "Apps must not include any content that
  facilitates the downloading or streaming of copyrighted content from
  third-party sources without authorization"
- Current App Store build is import-only (no YouTube code) — this is why
  approved
- TestFlight build can include the YouTube downloader (TestFlight bypasses
  App Review)
- The downloader is inside `#if !APP_STORE` guards — TestFlight gets it,
  App Store doesn't

## Maintenance cost

- YouTube rotates player.js obfuscation weekly — solver breaks
- yt-dlp community updates within 24-48 hours
- For iOS: ship a "solver patch" TestFlight build each rotation
- The iOS app downloads player.js at runtime — same freshness as yt-dlp
- yt-dlp-ejs's whole purpose is robustness against obfuscation changes

## Implementation plan

1. Generate standalone `yt.solver.core.js` IIFE + `meriyah` + `astring`
   bundle using `pnpm build` from yt-dlp-ejs repo, or extract from PyPI
   wheel
2. Bundle JS files as Swift resources (`Bundle.main.url(forResource:)`)
3. Write `YouTubeJSSolver.swift` — wraps JSContext, loads scripts, calls
   the `jsc` function, parses output JSON
4. Update `YouTubeClient.swift` to:
   - Fetch player.js from `https://www.youtube.com/s/player/{hash}/player_es6.vflset/en_US/base.js`
   - First call innertube without `n` token → YouTube responds with
     `serviceIntegrityDimensions` challenge
   - Call JS solver with the challenge → get `n` token
   - Second call innertube with `serviceIntegrityDimensions.poToken`
     populated → YouTube returns real audio URLs
5. Cache the player.js URL across calls (it changes ~weekly) and the
   solved `n` tokens (they're valid for ~5 min)

## Open question

- Will the App Store build's import-only behavior survive? Yes, because the
  YT solver code is inside `#if !APP_STORE` guards. The TestFlight build
  includes it; the App Store build doesn't.
