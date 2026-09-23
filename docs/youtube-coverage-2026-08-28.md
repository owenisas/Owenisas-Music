# YouTube Coverage — Owenisas Music

**Last updated: 2026-08-29**

On-device fetch (iPhone USB Debug): see **`youtube-iphone-download.md`** —
VISIONOS resolve was already fine; `URLSessionDownloadTask` + iOS YouTube UA
stalled at 0 bytes. Chunked Range `dataTask` is what actually saved files.

## Summary

Two-tier coverage. Tier 1 (no JS) handles the overwhelming majority of
mainstream music — verified **9/10** on a fresh sweep, with **no solver
needed at all**. Tier 2 (JS solver) targets kids/age-restricted content and
is **not shipped and not recommended** — see
`youtube-tier2-feasibility.md` for why.

| Tier | Clients | JS solver | Covers |
|---|---|---|---|
| **1 (shipped)** | VISIONOS → IOS → TVHTML5 | **no** | mainstream music, most videos |
| 2 (not shipped, not recommended) | WEB_EMBEDDED_PLAYER | yes | kids/age-restricted — YouTube rotates these faster than any client can track |

### Coverage sweep (2026-08-28, live, VISIONOS alone, no solver)

**9/10 succeed.** Only `XqZsoesa55w` (Baby Shark) fails — and **yt-dlp fails
it too at the same moment**, with a full Deno solver and `web_embedded`. The
control (Despacito / Rick Astley / Gangnam all HTTP 200 in the same run)
proves this is not rate limiting: YouTube is actively rotating protection on
that video.

| Video | Result |
|---|---|
| Despacito, Gangnam Style, Rick Astley, Uptown Funk, Bohemian Rhapsody, Nirvana, Adele Hello, Me at the zoo, Smash Mouth, Alan Walker, Ed Sheeran, Katy Perry, Wiz Khalifa, Shakira | HTTP 200 via VISIONOS, no cipher, no `n` |
| **Baby Shark `XqZsoesa55w`** | 403 — **yt-dlp also 403s** |
| Toto Africa `FTQbiNvZqa0`, a-ha `djV11GbcWDw` | dead at source (oEmbed 404) — not fixable by anyone |

**VISIONOS needs no solver**: its player response carries a plain `url` with
no `signatureCipher` and no `n` parameter. This is the durable path.

## Tier 1 — shipped (no JS solver)

`YouTubeClient.resolveAudio`:

1. Warm `https://www.youtube.com/watch?v=<id>&hl=en` (Safari UA, cookie jar)
2. Extract per-video `visitorData` from watch page HTML (~520 chars)
3. POST `youtubei/v1/player` with `X-Goog-Visitor-Id`
4. Client fallback: **VISIONOS** → **IOS**
5. Pick best audio format with a direct HTTPS URL

### Verified 2026-08-28 (iPhone 16 sim, real download path, ffprobe-valid)

| Video | Result | File |
|---|---|---|
| `kJQP7kiw5Fk` Despacito | HTTP 200 | 1,718,053 B, AAC 44.1kHz stereo, 281.6s |
| `9bZkp7q19f0` Gangnam Style | HTTP 200 | 1,539,911 B, AAC, 252.4s |
| `dQw4w9WgXcQ` Rick Astley | HTTP 200 | 1,300,631 B, AAC, 213.2s |
| `OPf0YbXqDm0` Uptown Funk | resolve OK | VISIONOS |
| `fJ9rUzIMcZQ` Bohemian Rhapsody | resolve OK | VISIONOS |
| `hTWKbfoikeg` Nirvana | resolve OK | VISIONOS |
| `YQHsXMglC9A` Adele Hello | resolve OK | VISIONOS |

### Required fixes discovered

1. **Watch-page warm** — POSTing to innertube cold gets throttled.
2. **`X-Goog-Visitor-Id` header** — per-video visitorData, not global.
3. **`parsePlayer` bug** — treated presence of `playabilityStatus` as error,
   rejecting `status: "OK"`. Fixed to reject only non-OK.
4. **Ephemeral URLSession** — `URLSessionConfiguration.default` attached the
   YouTube cookie jar to googlevideo.com → HTTP 403. Ephemeral + no cookie
   storage fixes it.

## Tier 2 — NOT shipped (requires JS solver)

### The gap: `XqZsoesa55w` (Baby Shark)

yt-dlp (2026.08.19) client sequence for this video:
- `visionos` → **UNPLAYABLE**
- `tv_downgraded` → **UNPLAYABLE**
- `web_embedded` → needs **GVS PO token** ("Detected experiment to bind GVS
  PO Token to video ID for web_embedded client")
- `web` → SABR forced, formats missing

With `--remote-components ejs:github` (real solver lib, not the stale cached
one) yt-dlp succeeds: `c=WEB_EMBEDDED_PLAYER` URL with `n=` + `sig=`.

**Critical:** with a cold cache and no remote components, yt-dlp's own solver
FAILS on this video too. Earlier apparent success was a warm-cache artifact.
So this is genuinely solver-gated, not a request-shape problem.

### Why not shipped

Investigated 2026-08-28 — see `docs/youtube-tier2-feasibility.md` for the
full analysis. Summary of findings:

**The PO token is not the blocker.** `web_embedded`'s
`GVS_PO_TOKEN_POLICY` is `required=False` on https/dash/hls, and yt-dlp runs
with `PO Token Providers: none` yet still succeeds. The "Detected experiment
to bind GVS PO Token" log line is noise. Baby Shark works purely by solving
**n/sig** — no PO token is required or used. This corrects the earlier
assumption that a PO token was needed.

**The real blocker is `EMBEDDER_IDENTITY_DENIED`.** Replaying yt-dlp's exact
`web_embedded` context from Python returns
`PLAYABILITY_ERROR_CODE_EMBEDDER_IDENTITY_DENIED` (`Error code: 152 - 18`)
for every `embedUrl` variant — none, `youtube.com/embed/<id>`,
`youtube.com/watch?v=<id>`, `youtube.com/`, and yt-dlp's own
`reddit.com` default.

`web_embedded` requires an embedder identity handshake: fetch the embed client
config and pass its `encryptedHostFlags` in `contentPlaybackContext`. That is
a third, undocumented, rotating request type we do not implement.

### Recommendation

**Do not build Tier 2.** Tier 1 covers the music-library use case. Tier 2
targets kids/age-restricted content at the cost of ~2.5 MB player.js per
video plus TestFlight rebuilds every 1–4 weeks as YouTube rotates.

If ever needed: solve the embedder-identity step first. If `encryptedHostFlags`
cannot be obtained reliably, the remaining solver work is pointless.

## Genuinely unavailable (not fixable)

| Video | Status |
|---|---|
| `FTQbiNvZqa0` Toto Africa | oEmbed 404 — dead/region-blocked |
| `djV11GbcWDw` a-ha Take On Me | oEmbed 404 — dead/region-blocked |

Confirmed with `https://www.youtube.com/oembed?url=...` returning 404.
yt-dlp also fails these. Not a client-side gap.

## Binary separation (verified 2026-08-28)

| Binary | YouTube strings | Solver refs | DownloadView |
|---|---|---|---|
| App Store (`APP_STORE`) | 0 | 0 | 0 |
| TestFlight | 29 | 11 | 1 |

App Store build is unchanged from the approved import-only release.

## Artifacts

- TestFlight IPA: `build/OwenisasMusic.ipa` (4.3 MB, Mach-O arm64)
- Verified audio: `/tmp/final_kJQP7kiw5Fk.m4a`, `/tmp/final_9bZkp7q19f0.m4a`,
  `/tmp/final_dQw4w9WgXcQ.m4a`
- Related: `docs/youtube-js-solver-research.md`,
  `docs/decision-2026-08-27-youtube-solver.md`
