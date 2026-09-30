# Owenisas Music App Store release

Last updated: 2026-09-29

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
- Latest uploaded `1.1 / 202609231913` is `VALID`, `APP_STORE_ELIGIBLE`, internal `IN_BETA_TESTING`, external `READY_FOR_BETA_SUBMISSION`.
- No active review submission; three historical submissions are `COMPLETE`.
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

- Manual-signing build `9701d061-595d-458c-b076-398eec2ed820` finished successfully from source `faa2869`, using stable Xcode `26.4.1 / 17F6`, iOS SDK `26.4` and worker OS build `25E245`.
- Exact `1.1 / 202609292030` IPA passed strict distribution-signature verification for all five bundles. Bundle versions, App Groups and privacy manifests agree; the main executable has Production iCloud, CloudDocuments and ubiquity-container entitlements.
- Apple upload `6c176798-8c0a-4c29-8c77-3c74e571294f` was committed, but ingestion failed with `90626 Invalid Siri Support`: four intent descriptions and the Watch device enum used reserved `iPhone` names. It never became an ASC build or TestFlight-ready.
- The current successor replaces only the rejected static metadata wording (and the SDK-27 counterpart); playback, identifiers, runtime dialogs and downloader behavior are unchanged. Build number is bumped to `202609292344` across the project and EAS config.
- The new compiled App Intent gate checks the archived app and nested bundles before export. It reproduced all seven locations in the actually rejected IPA; source/compiled metadata and signing tests now total **32 passing**, alongside **7 widget integration tests**.

Not yet verified for the metadata-fixed successor: fresh cloud archive/export, exact successor IPA, ASC `VALID`, external Beta App Review approval and usable public-group assignment. Prior binary validation is not transferred to the new candidate.

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
