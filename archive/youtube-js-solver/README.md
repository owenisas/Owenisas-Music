# Archived: YouTube JS n-sig solver (Tier 2)

**Last updated: 2026-09-22**

Moved out of the app target. No download path used it (Tier 1 VISIONOS resolve needs no
solver; see `docs/youtube-coverage-2026-08-28.md`), its live test failed, and the three JS
files (~310 KB, `youtube-solver.js` a byte-identical copy of `-lib.js`) were being bundled
into every build, including the App Store one.

Restore by moving `YouTubeJSSolver.swift` back under `Owenisas Music/` and the `.js` files
back under `Owenisas Music/Resources/` (both are file-system-synchronized folders).
