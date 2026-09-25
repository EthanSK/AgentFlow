# Public Agent Flow releases

[v2.0.345](https://github.com/EthanSK/AgentFlow/releases/tag/v2.0.345) is the first public
Developer ID-signed, Apple-notarized release. Its universal ZIP was downloaded back from GitHub
and matched the published SHA-256. Source: `0df26e3d801800b5d9e1025454fd169690710aaf`;
exact-build gate: 365 named tests across 13 suites.

Every later download must pass the same gates below. A `VoiceInk Local Signing` or ad-hoc app
is only a local build, even when `codesign --verify --deep --strict` succeeds.

## Release boundary

1. Work from a clean `main` commit. Increment both main-app `CURRENT_PROJECT_VERSION` settings;
   never reuse an installed or published build number. Preserve the unrelated dirty VoiceInk
   checkout and the official `/Applications/VoiceInk.app`.
2. Build and run the full named unit suite on Ethan's Mac Mini. `scripts/test-public-release.sh`
   uses Xcode's normal test action first. Only when TestManager executes zero named tests does
   it use the already-built full-suite `xcrun xctest` fallback. The summary and individual
   named passes must agree, with at least the current 365-test floor. Include the
   cross-app selection fallback, privacy, and fresh-setup model guards in the
   exact source being signed.
3. On the Mini run `scripts/package-public-release.sh /private/tmp/<fresh-task-output> --build-only`.
   It checks the pinned universal `whisper.cpp` dependency, runs the exact full suite, builds
   a separate universal Release app, embeds GPLv3, and writes a bundle-preserving prebuilt ZIP,
   `build-receipt.json` and `test-summary.txt`. Keep the detailed test logs on the Mini.
4. Transfer those three files to a fresh directory on the signing Mac, not raw recursive `scp`
   of the `.app`. With the exact same clean source commit and the dedicated Keychain profile
   below, run `scripts/package-public-release.sh <transferred-output> --sign-prebuilt`.
   It checks the source/build and file hashes before extraction, signs nested code and the
   outer app with Developer ID and hardened runtime, retains Automation, submits to Apple,
   staples, and produces the public ZIP, SHA-256 file and source-bound `release.json`.
   Sparkle's bare `Autoupdate` executable must be signed before its framework, using
   `Versions/Current/Autoupdate`, not a hard-coded version-A path. Sparkle 2 packages version B;
   signing only the enclosing framework can pass local checks but fail Apple's notarization.
   The MacBook does not build or run native tests. The optional default `--complete` mode runs
   both stages on the Mini only when its own signing identity and isolated profile are usable.
   Then run `scripts/publish-public-release.sh <transferred-output>`.
   It verifies the notarized extracted app again, checks the exact source commit exists on
   GitHub, creates a draft, checks its three assets, then publishes the release. It refuses
   to overwrite an existing tag's release.
5. Only after the public ZIP works, update README, setup/build guidance and the Pages site to
   point to the verified download. A source change to the native app also needs the separate
   five-second warned local install/restart and live PID, CDHash, signature, entitlement and
   rollback checks in `AGENTS.md`.

## Isolated Agent Flow notarization credential

Create a new Apple app-specific password named **Agent Flow notarization** at
[account.apple.com](https://account.apple.com/) under **Sign-In and Security → App-Specific
Passwords**. Do not reuse another project's password. On the signing Mac, run this in an interactive
Terminal session under the signing user's account, substituting only the Apple Account email:

```sh
xcrun notarytool store-credentials AgentFlowRelease \
  --apple-id '<your Apple Account email>' --team-id T34G959ZG8
xcrun notarytool history --keychain-profile AgentFlowRelease --output-format json
```

Let `notarytool` prompt for the new app-specific password. Do not add `--password` to the command,
paste the password into chat, or put it in an environment variable, shell history, repository file,
CI secret, release asset, or log. Omit `--sync` so this profile remains local to that Mac. The
packaging script uses only this fixed profile name and validates it before signing. A separately
named password can be revoked independently in the Apple Account, but it is **not** an Apple
per-app permission boundary; treat the signing Mac and its Keychain access as sensitive.

Create and validate the profile in the signing Mac's logged-in user session. A non-interactive SSH
`keychainLocked` error does not establish that the profile is absent or invalid. Do not work
around it by placing the macOS login password in automation; any release runner must prove it
can access the intended Keychain profile in its actual execution session before it is enabled.

Apple also supports a **team** App Store Connect API key for `notarytool`, but team keys apply
across all apps; individual API keys cannot authenticate `notarytool`. A Developer ID
certificate alone does not complete notarization. See Apple's
[app-specific-password instructions](https://support.apple.com/en-gb/102654) and
[`notarytool` Keychain guidance](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

An automatic release runner is not yet registered. The manually verified public release does not
establish safe CI access to the signing identity or Keychain. Do not attach those credentials to
a public-repository self-hosted runner; verify a separate security boundary before automation.

The public release process must never silently fall back to self-signing or skip Apple
notarization. Publishing a ZIP is separate from implementing an in-app automatic updater.
