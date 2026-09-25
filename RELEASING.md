# Public AgentFlow releases

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
   named passes must agree, with at least the last accepted 347-test floor. Include the
   cross-app selection fallback, privacy, and fresh-setup model guards in the
   exact source being signed.
3. Create and validate the dedicated `AgentFlowRelease` `notarytool` Keychain profile on the Mini
   using the steps below, then run `scripts/package-public-release.sh /private/tmp/<fresh-task-output>`.
   The script checks
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

## Isolated AgentFlow notarization credential

Create a new Apple app-specific password named **AgentFlow notarization** at
[account.apple.com](https://account.apple.com/) under **Sign-In and Security → App-Specific
Passwords**. Do not reuse another project's password. On the Mini, run this in an interactive
Terminal session under the signing user's account, substituting only the Apple Account email:

```sh
xcrun notarytool store-credentials AgentFlowRelease \
  --apple-id '<your Apple Account email>' --team-id T34G959ZG8
xcrun notarytool history --keychain-profile AgentFlowRelease --output-format json
```

Let `notarytool` prompt for the new app-specific password. Do not add `--password` to the command,
paste the password into chat, or put it in an environment variable, shell history, repository file,
CI secret, release asset, or log. Omit `--sync` so this profile remains local to the Mini. The
packaging script uses only this fixed profile name and validates it before building. A separately
named password can be revoked independently in the Apple Account, but it is **not** an Apple
per-app permission boundary; treat the Mac Mini and its Keychain access as sensitive.

Apple also supports a **team** App Store Connect API key for `notarytool`, but team keys apply
across all apps; individual API keys cannot authenticate `notarytool`. A Developer ID
certificate alone does not complete notarization. See Apple's
[app-specific-password instructions](https://support.apple.com/en-gb/102654) and
[`notarytool` Keychain guidance](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

An automatic release runner is not yet registered. Do not enable one, publish a binary, or add
a download link until its security boundary and the notarized end-to-end gate are verified.

The public release process must never silently fall back to self-signing or skip Apple
notarization. Publishing a ZIP is separate from implementing an in-app automatic updater.
