# Owenisas Music App Store release

Last updated: 2026-09-30

## Candidate and authorization

- Source baseline: `cb5cd01fa1e8301107505f1adb0232e332a2c598`, branch `overhaul/playback-downloader-sync`.
- Successor: marketing version `1.1`, build `202609292344`; feature candidate `55013eb` and signing recovery `faa2869` are pushed and remote-verified. The current successor also fixes Apple's Siri metadata ingestion rejection.
- Operator requested audit followed by App Store submission, with downloader changes deferred.
- Operator separately approved uploading source to the existing EAS project using free quota only. No paid upgrade or spend approved.
- Preserve existing production variant (`APP_STORE`, `OWENISAS_DISTRIBUTION=appstore`); no downloader implementation changes. This existing variant is import-only, unlike the personal/TestFlight variant.
- TestFlight upload, external Beta App Review, and assignment of an unexpired approved build to the existing public group are explicitly authorized. Final App Store review submission is a separate gate.
- Signing remediation is approved: register the Watch widget identifier, associate the existing App Group with both Watch identifiers, and create profiles for all five bundles using the existing distribution certificate. No certificate revocation, paid upgrade or spend is authorized.

## Live state checked

- ASC app: `6760303576`, bundle `com.Owenisas-Music`.
- App Store `1.0` is `READY_FOR_DISTRIBUTION`.
- Current `1.1 / 202609292344` (`b211a945-881c-4148-bb40-7f24a2f7ac1c`) is `VALID`, unexpired, `APP_STORE_ELIGIBLE`, internal `IN_BETA_TESTING`, external `WAITING_FOR_BETA_REVIEW`.
- Exact build is assigned to external public group `2f2c9598-c4fc-4248-838d-376fe262cad4`; Beta App Review submission is `WAITING_FOR_REVIEW` (submitted September 30 at 00:00:19 PDT). Public recruitment remains blocked pending Apple approval.
- Older `1.1 / 202609231913` is not the current feature/safety release.
- Existing en-US screenshots: one iPhone 6.5-inch and one iPad Pro 12.9-inch, both `COMPLETE`. Current-candidate visual coverage still required.
- Local release host unsuitable: macOS `27.2 / 26B5091g`, Xcode `27.0 / 27A266a` beta. Mac mini SSH timed out. Do not archive a release locally.
- Existing EAS production signing environment variable names are present; secret values were not retrieved. Prior successful cloud release used the old single-target version.

## Audit and verification

Baseline full unit suite: 289 total, 287 passed, 0 failed, 2 skipped. Separate live simulator download UI test passed. Both are baseline evidence, not proof for the successor binary or physical-device iCloud sync.

Confirmed risks under remediation:
- same-name audio import overwrite and delete-before-copy;
- re-added songs retaining timestamps older than cloud deletion tombstones;
- silent writable in-memory fallback after persistent-store failure;
- backup playlist ordering/identity/cover loss;
- duplicate queue-slot removal;
- stale player metadata/resume cache after cloud merge;
- hidden sync mirror errors;
- playback-start failure handling.

Parent changes prepared:
- required-reason privacy manifests for Watch, Share and Widget; main App Group/file-picker reasons;
- privacy-policy wording reconciled with default-on iCloud transfer and propagated deletions;
- production cloud workflow uses verified per-target manual App Store profiles, successor-bound version/build checks, per-product privacy checks, and validate-only Apple step; automatic provisioning is deliberately disabled.
- EAS source archive excludes backend, credentials, personal cookies, logs, historical experiments and unrelated tooling.

Integrated simulator unit evidence: **338 passed, 0 failed, 2 skipped** (`build/timer-qa/full-green.xcresult`). Focused post-SDK-guard Siri tests: **19 passed**. Sleep timer deep-link/UI test passed; compact native simulator Dynamic Island was inspected. Expanded Island, native Lock Screen, physical Siri/Watch/iCloud behavior remain unverified.

### Signing recovery

- First EAS attempt `c39ed09c-152a-4c90-879a-e12cb825ac6d` failed before compilation: automatic signing requested missing Apple Development keys/profiles and suggested certificate revocation. No revocation was performed.
- Both Watch identifiers now have `group.com.Owenisas-Music` assigned, verified by reopening each Developer Portal configuration.
- Five ACTIVE App Store profiles were created and downloaded through ASC. Their certificate fingerprints match the existing cloud-imported P12 identity; all contain the App Group, and the main profile permits its iCloud container and Production environment.
- Five project-scoped production SECRET profile variables are configured in the existing EAS project. No profile contents or keys are committed or logged.
- `.eas/build/install-profiles.py` rejects wrong team/bundle, development/ad hoc/enterprise scope, missing App Group/iCloud, expiry and certificate mismatch before installing anything. It creates the explicit five-bundle export map. Cloud-only target rewrites preserve Debug signing and inherited extension flags.
- Local signing regression suite: **22 passed**; widget integration suite: **7 passed**. Real-profile install, per-target project rewrite and export-map rehearsal passed without a local archive. Profiles are installed into both modern Xcode and legacy discovery directories; CloudDocuments and ubiquity-container permissions are also validated, including Apple's legitimate wildcard service grants.

### Cloud and ingestion evidence

- Manual-signing build `9701d061-595d-458c-b076-398eec2ed820` finished successfully from source `faa2869`, using stable Xcode `26.4.1 / 17E202`, iOS SDK `26.4` and worker OS build `25E253`.
- Exact `1.1 / 202609292030` IPA passed strict distribution-signature verification for all five bundles. Bundle versions, App Groups and privacy manifests agree; the main executable has Production iCloud, CloudDocuments and ubiquity-container entitlements.
- Apple upload `6c176798-8c0a-4c29-8c77-3c74e571294f` was committed, but ingestion failed with `90626 Invalid Siri Support`: four intent descriptions and the Watch device enum used reserved `iPhone` names. It never became an ASC build or TestFlight-ready.
- The current successor replaces only the rejected static metadata wording (and the SDK-27 counterpart); playback, identifiers, runtime dialogs and downloader behavior are unchanged. Build number is bumped to `202609292344` across the project and EAS config.
- The new compiled App Intent gate checks the archived app and nested bundles before export. It reproduced all seven locations in the actually rejected IPA; source/compiled metadata and signing tests now total **32 passing**, alongside **7 widget integration tests**.

### Current successor distribution

- Source `3378f42ecce81f8f0e08e62661beff6a692476bf` is pushed and remote-verified. EAS build `8a4af6a6-e60d-4772-8310-243edcefdc96` finished on stable Xcode `26.4.1 / 17E202`.
- Exact IPA SHA-256: `424034defdfab8658f8a94a8980e05a214c85b5061a934fc47fcd2e51d147ebb`. All five distribution bundles passed strict signature, version/build, App Group and privacy checks; main Production iCloud is verified. Compiled App Intent reserved-name checks passed for all four metadata-bearing bundles.
- ASC upload/build `b211a945-881c-4148-bb40-7f24a2f7ac1c` reached ingestion `COMPLETE` and processing `VALID`. Expiration: December 28, 2026 at 22:57:46 PST. Internal state: `IN_BETA_TESTING`.
- Candidate-specific en-US What to Test notes were written and read back. Public external group membership was independently verified through both build-group lookup and the exact group's build relationship.
- External Beta App Review was submitted and read back as `WAITING_FOR_REVIEW`; external build state remains `WAITING_FOR_BETA_REVIEW` after bounded observation. The public link `https://testflight.apple.com/join/HHqw7nsT` still says it is not accepting new testers. Assignment is complete, but external approval and public installability are **not** complete.
- No paid upgrade, certificate revocation or downloader implementation change occurred. No App Store review submission was made in this distribution step.

Remaining release gates: Apple's external Beta App Review approval and subsequent public-link verification; expanded Island/native Lock Screen and physical Siri/Watch/iCloud runtime QA; exact-candidate App Store screenshots/metadata and any separately approved App Store submission.

## Downloader-enabled TestFlight correction

- Operator explicitly requires Download to remain in TestFlight. The previous `202609292344` upload used the import-only `APP_STORE` variant; source preservation did not preserve the feature in the binary. It remains waiting for external review and must not be described as downloader-enabled.
- EAS `testflight` profile now uses `.eas/build/testflight-ios.yml`, production signing secrets, inherited extension flags without `APP_STORE`, and `OWENISAS_DISTRIBUTION=personal`. The separate App Store workflow is unchanged.
- Stable SDK compile required guarding the SDK-27 background scheduler call with the same SDK availability discriminator used by MediaIntents; SDK 26 uses synchronous scheduling. The first correction cloud run exposed this compile error. The next archived successfully but a short-string binary marker failed: an optimized Swift probe confirmed short strings need not survive `strings`. The gate now uses the long Download-screen instruction and the downloader URL.
- Successful EAS build: `c5520cd2-1535-4a52-9e2a-919c4db40e44`; pushed source `94a299f38f66de246b6d65588f37e144da9e0ea7`; version/build `1.1 / 202609300942`. Exact IPA SHA-256: `4a47a4b7559ac40479154c13cb0af5e722cc355a0b1d7c31a3198d862adbcdb4`.
- Exact IPA verification proves Download-screen instruction and downloader endpoint in the executable, URL/text Share activation, all five valid signatures, matching versions, App Groups/privacy manifests, Production iCloud, and four compiled intent metadata bundles. These are binary-presence checks, not a fresh physical-device end-to-end download test. Release regression suite: **35 passing**.
- ASC upload/build `3e05817a-98ba-41a1-9d9d-cbce0607525f` is ingestion `COMPLETE`, processing `VALID`, internal `IN_BETA_TESTING`. Updated test notes were read back. Exact build membership in the public external group was read back.
- External review submission was attempted but Apple rejected it: another build in the same train is already in beta review. The new build remains `READY_FOR_BETA_SUBMISSION`, with no review submission. The older import-only build remains `WAITING_FOR_BETA_REVIEW`. Do not claim the new build is submitted or publicly available. No older build was expired and no review was canceled.

## iCloud transfer-error reporting follow-up

- The connected iPhone 13 mini has `1.1 / 202609300942`, 91 local song folders, 91 songs in sync state, and 91 mirrored-folder entries. Mirrored means copied to/seen in the local ubiquity container, not server-confirmed upload. No library or sync reset was performed; full iCloud quota on this device is not yet confirmed.
- Local source now reads Apple's asynchronous upload/download errors from URL resource values and metadata-query results, preserves query errors during directory refresh, and propagates song and library-JSON transfer failures to the existing Settings status. Quota, local-device storage, connectivity, timeouts, unavailable service/files and unknown errors have explicit messages. Local storage exhaustion is no longer mislabeled as full iCloud storage.
- Nine new transfer-error tests passed. Full simulator unit suite: **347 passed, 0 failed, 2 skipped** (349 logical tests; 367 passing invocations including parameterized cases), result `build/final-integrated-derived/Logs/Test/Test-Owenisas Music-2026.09.30_20-21-03--0700.xcresult`. Existing Siri test audio-session runtime warnings were emitted. `git diff --check` passed.
- These source changes are not yet in a new TestFlight binary or installed on the phone. Device daemon logs remain unavailable without operator-local administrator authentication; do not attribute the existing stall to quota until confirmed.

## Draft 1.1 release notes

- Sync your songs, playlists, likes and listening history across devices with iCloud Drive.
- Control playback from Home Screen and Lock Screen widgets and Control Center.
- Share audio files directly into your library.
- Browse and play your library on Apple Watch, including offline playlists.
- Improved playback transitions, library ordering, lyrics, sleep timer and accessibility.
- Improved audio import safety, backup restoration and sync error reporting.

## Release gates

1. Reconcile independent fixes and rerun focused then full tests.
2. Compile and exercise production variant; inspect unobstructed iPhone/iPad and Watch runtime where available.
3. Inspect exact EAS source archive for required inputs and absence of secrets/personal media.
4. Run free-quota-only pinned non-beta cloud build. Stop on quota/payment/auth failures; no automatic paid fallback.
5. Download and verify exact IPA, all bundle versions, distribution signing, iCloud/App Group entitlements and privacy manifests; validate with Apple.
6. Obtain exact-candidate Apple upload approval (build number becomes consumed), upload and read back `VALID`.
7. Obtain specific metadata/version/build attachment and submission approvals; keep one review draft, read back version and review submission states.
8. Report `WAITING_FOR_REVIEW` only from live ASC readback, not from command success alone.
