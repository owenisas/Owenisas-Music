# Tier 2 Feasibility — PO-gated / kids videos

**Last updated: 2026-08-28**
Question: can we support videos like Baby Shark (`XqZsoesa55w`) on-device?

## Status: ROOT CAUSE RESOLVED — not a bug in our code

### The real finding (2026-08-28, end of session)

**yt-dlp itself now 403s on Baby Shark.** Control test, same minute, same IP:

| Video | yt-dlp + full Deno solver + `web_embedded` | Our prototype |
|---|---|---|
| Despacito `kJQP7kiw5Fk` | HTTP 200 | — |
| Rick Astley `dQw4w9WgXcQ` | HTTP 200 | — |
| Gangnam Style `9bZkp7q19f0` | HTTP 200 | — |
| **Baby Shark `XqZsoesa55w`** | **HTTP 403** | **HTTP 403** |

The control proves my IP is not rate-limited. Baby Shark is blocked **for
everyone** at this moment. **The step-5 blocker was never our bug — it was
chasing a target YouTube rotates.**

### What was proven along the way (all still valid)

- **Solver is correct.** Feeding yt-dlp's own player.js + its own challenge
  `TuXMRZQJ-nA-vP6PdNI` reproduces its exact `n` (`RWkc1JGRdwYUJQ`) — the
  precise value in yt-dlp's working URL. Never a solver bug.
- **`ns` is poison** (reproducible 3/3): adding our `ns` to a known-good
  yt-dlp URL flips it to 403, while adding our `n` does not.
- **`VISIONOS` needs no solver at all** — its response carries a plain `url`
  with no cipher and no `n`. That is what Tier 1 already does.
- **`IOS` returns OK with no cipher and no `n`** even on Baby Shark — the
  403 there is a fetch gate, not a missing-solver gate.
- `WEB_EMBEDDED_PLAYER` always issues `n` + `ns`; removing `sts` or
  `encryptedHostFlags` yields `playability=ERROR`.
- **Real bug found + fixed:** client version was hardcoded to
  `2.20260708.00.00`; live value is `2.20260828.01.00`.

### Verdict

Tier 2 as specified ("kids/age-restricted via `web_embedded` + JS solver") is
**not achievable as a durable capability**. YouTube rotates these URLs on a
timescale shorter than an app release cycle; even yt-dlp with a live Deno
solver loses them. The earlier "yt-dlp works, we don't" observations were
transient windows, not a durable gap.

Any future attempt must start with a live control ("does yt-dlp get this video
right now?") **before** writing code. Do not debug against a video yt-dlp
currently fails.


### Step 5 — what was tried (all 403)

| Hypothesis | Result |
|---|---|
| Player.js generation (`player_ias` vs `player_es6` vs `player_embed_es6`) | `player_ias` confirmed (2,885,713 b, captured from yt-dlp) — still 403 |
| Hardcoded client version | **Real bug found + fixed**: was `2.20260708.00.00`, live is `2.20260828.01.00` — still 403 |
| Minimal vs full desktop/client context | Full context replicated (osName/platform/browserName/originalUrl/embeddedPlayerContext) — still 403 |
| `embeddedPlayerEncryptedContext` | Extracted + sent — still 403 |
| Cookies on player POST (warm watch + youtube.com) | 4 combos all 403 |
| Param order (`n` position) | Reordered to yt-dlp's exact key order — still 403 |
| URL encoding / duplicate params | None (42 = 42, no dupes) — still 403 |
| Header/UA on the final fetch | yt-dlp's URL works with **zero** headers, so headers are irrelevant |
| Expiry / session drift | Both unexpired, `ns` identical — still 403 |

### Decisive negative result

Swapping **any single** value from our URL into yt-dlp's working URL
(`n`, `sig`, `lsig`, `cps`, `mn`, `ns`, `spc`, `bui`, `met`) breaks it —
including values unrelated to solving (`bui`, `met`, `mn`). The URL is a
**signed, session-bound unit**: it cannot be decomposed, so per-parameter
diffing cannot localize the fault. This is why the blocker survived every
param-level hypothesis above.

### What is definitively ruled out

- PO token (not required; yt-dlp runs with `PO Token Providers: none`)
- The JS solver (provably correct — reproduces yt-dlp's `n` bit-for-bit)
- Player.js generation (captured directly from yt-dlp)
- Client version mismatch (found and fixed)
- Headers, cookies, param order, encoding, expiry


**Decision (2026-08-28): Tier 2 paused.** Thomas chose to install the
TestFlight IPA and report real-world misses before more Tier 2 work. Reopen
only if reported failures are actually kids/age-restricted content. See
`docs/youtube-coverage-2026-08-28.md` for the shipped Tier 1 scope.

### Verification status of each claim

| Claim | How verified |
|---|---|
| Steps 1–4 work | Python prototype (`/tmp/tier2_proto.py`), live innertube |
| Step 5 fails | HTTP 403 on every header/cookie combination |
| PO token not required | `GVS_PO_TOKEN_POLICY` all `required=False`; yt-dlp runs with `PO Token Providers: none` and succeeds |
| `sig` + `n` both mandatory | Removing either from yt-dlp's known-good URL → 403 |
| Only `fexp` droppable | Removed each of 22 params individually; 21 → 403 |
| sig length mismatch | Ours 104 chars vs yt-dlp's 100, same 42-param URL shape |

### Step-by-step state

| # | Step | State |
|---|---|---|
| 1 | GET embed config → `encryptedHostFlags` | ✅ **VERIFIED** (124 chars) |
| 2 | POST player as `WEB_EMBEDDED_PLAYER` | ✅ **VERIFIED** — `playability=OK`, 4 audio formats |
| 3 | Fetch player.js + `signatureTimestamp` | ✅ **VERIFIED** — `sts=20684` |
| 4 | Solve `n` + `sig` in JS | ✅ **VERIFIED** — both solve, deterministic |
| 5 | Fetch the final URL | ❌ **HTTP 403** |

### What unblocked steps 1–2: `signatureTranscript` (sts)

A `web_embedded` POST without `signatureTimestamp`
returns `UNPLAYABLE`. Adding `sts` (from player.js) returns **OK**.
`_video.py:2696` — `context['signatureTimestamp'] = sts`.

### PO token is NOT required (confirmed)

`INNERTUBE_CLIENTS['web_embedded']`:
```
GVS_PO_TOKEN_POLICY = {https: required=False, dash: required=False, hls: required=False}
```
yt-dlp runs with `PO Token Providers: none` and still succeeds...[truncated]