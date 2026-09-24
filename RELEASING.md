# Public VoiceInk++ releases

The website currently offers a source build. Do not add a binary download link until a
Developer ID-signed, Apple-notarized archive has passed the gates below and a matching GitHub
Release is public. A `VoiceInk Local Signing` or ad-hoc app is only a local build, even when
`codesign --verify --deep --strict` succeeds.

## Release boundary

1. Work from a clean `main` commit. Increment both main-app `CURRENT_PROJECT_VERSION` settings;
   never reuse an installed or published build number. Preserve the unrelated dirty VoiceInk
   checkout and the official `/Applications/VoiceInk.app`.
2. Build and run the full named unit suite on Ethan's Mac Mini. `scripts/test-public-release.sh`
   uses Xcode's normal test action first. Only when TestManager executes zero named tests does
   it use the already-built full-suite `xcrun xctest` fallback. The summary and individual
   named passes must agree, with at least the current 344-test floor.
3. Set `VOICEINK_NOTARY_PROFILE` to a working `notarytool` Keychain profile on the Mini, then
   run `scripts/package-public-release.sh /private/tmp/<fresh-task-output>`. The script checks
   the pinned universal `whisper.cpp` dependency, builds a separate Release app, embeds the
   complete GPLv3 copy, signs nested code and the outer app with Ethan's Developer ID and
   hardened runtime, retains the outer Automation entitlement, submits to Apple, staples the
   ticket, and creates a ZIP, SHA-256 file, and source-bound `release.json`.
4. Transfer the output directory as a bundle-preserving archive, not raw recursive `scp` of
   the `.app`. On the MacBook, run `scripts/publish-public-release.sh <transferred-output>`.
   It verifies the notarized extracted app again, checks the exact source commit exists on
   GitHub, creates a draft, checks its three assets, then publishes the release. It refuses
   to overwrite an existing tag's release.
5. Only after the public ZIP works, update README, setup/build guidance and the Pages site to
   point to the verified download. A source change to the native app also needs the separate
   five-second warned local install/restart and live PID, CDHash, signature, entitlement and
   rollback checks in `AGENTS.md`.

An Apple app-specific password or a team App Store Connect API key may be used to create the
Mini's `notarytool` profile. Keep its value out of chat, shell history, repository files,
release assets, and logs. An individual App Store Connect API key cannot authenticate
`notarytool`. A Developer ID certificate alone does not complete notarization.

The public release process must never silently fall back to self-signing or skip Apple
notarization. Publishing a ZIP is separate from implementing an in-app automatic updater.
