# Public Agent Flow releases

This file qualifies public distribution. Ethan’s early local updates follow the local-first
rule in `AGENTS.md` and `UPDATING.md`; do not make local use wait for this full pipeline.
The existing public scripts still combine full tests, build and signing, so the installing
owner must use or separate their viable local build/signing stage without weakening public
qualification. Preserve one source identity, stable signing and the guarded local restart.
User-corrected — 2026-11-14.

The release scripts publish the version read from the app source. Keep the public
download, setup guide and website version aligned after the artifact passes the
gates below. Automated public builds, full tests, Developer ID signing and notarization
all run on a disposable GitHub-hosted Mac. Local installation keeps its separate
Mini-based flow and does not determine public-release readiness.
Use a fresh `.noindex` output directory and set `AGENTFLOW_PACKAGES_DIR` to an existing
reviewed Swift package cache if needed. Never substitute a local self-signed ZIP for
the notarized public artifact. `SHA256SUMS` contains only downloadable filenames, so
the documented `shasum -a 256 -c SHA256SUMS` works from a clean download directory.

## Automatic signed updates

Trusted native/release changes pushed to `main`, or a manual dispatch, start
`.github/workflows/release.yml` on a GitHub-hosted Apple Silicon Mac. It builds the
pinned speech dependency, runs the complete named test gate and builds a separate
universal Release app. No Fleet worker, personal Mac or saved GitHub CLI login is
part of this automated release.

The final app and nested code use the existing Developer ID identity. Notarization,
stapling and extracted-download checks precede publication. Sparkle's final ZIP
signature and `appcast.xml` preserve the key for account `com.ethansk.AgentFlow`;
only its public key belongs in the app's top-level `SUPublicEDKey`.

The job imports the signing material from encrypted repository Actions secrets
into a temporary Keychain, using the explicit job-local `ReleaseCI` notary profile.
It downloads checksum-verified Sparkle tools into the job's temporary directory.
It publishes immutable assets through the scoped GitHub job token, makes the draft
latest, then downloads the public assets and checks their hashes. Existing tags
and releases are never overwritten. Temporary signing material is removed even
on failure, and the hosted Mac is discarded after the job.

The app reads the latest `appcast.xml` and shows Sparkle's standard update dialog.
Its relaunch waits for the existing all-session quit guard; `UPDATING.md` owns the
attended bootstrap install. This workflow does not replace the running local app.

[v2.0.365](https://github.com/EthanSK/AgentFlow/releases/tag/v2.0.365) separates
different context section types with one blank line, keeps matching types compact,
and leaves apostrophes/quotation marks readable in XML text while preserving safe
attribute escaping. Source: `d00c8c3bcc4e96c1e68a12685849d4e5d71a1da5`;
exact-build gate: 459 named tests across 18 suites through Xcode's canonical action.
The universal Release archive is Developer ID signed, Apple notarized and stapled;
the downloaded public ZIP matched SHA-256
`da3558e4be95639e91ab0bb1aa2ca88c02fd8664a446866548afb2c0b825d744`.

[v2.0.364](https://github.com/EthanSK/AgentFlow/releases/tag/v2.0.364) publishes plain
History previews, natively rendered context, and an explicitly labelled session
timing window for short speech without live callbacks. Stored/copied content and
the separate recovery draft remain unchanged.
Source: `ebc465a5c0d358e3c4592e9bab5aadcecb3d8f44`;
exact-build gate: 457 named tests across 18 suites through Xcode's canonical action.
The existing Mini-built universal
Release archive was Developer ID re-signed and notarized without rebuilding native code
or replacing the separately installed local-signing app. Release checksums bind the public
artifact; later `main` commits contain documentation and media, not different native code.

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
2. The GitHub-hosted Mac runs the full named unit suite. `scripts/test-public-release.sh`
   uses Xcode's normal test action first. Only when TestManager executes zero named
   tests does it use the already-built full-suite `xcrun xctest` fallback. The summary
   and individual named passes must agree, with at least the current 365-test floor.
   Include the cross-app selection fallback, privacy and fresh-setup model guards in
   the exact source being signed. GUI/session-dependent tests must actually pass on
   the hosted Mac; do not skip them or delegate them to a personal machine.
3. The job runs `scripts/package-public-release.sh <fresh-output> --complete` with
   the hosted machine selected as `AGENTFLOW_BUILD_HOST`. It checks the pinned
   universal `whisper.cpp` dependency, runs the full suite, then builds a separate
   universal Release app and embeds GPLv3. Detailed test logs remain with the job's
   output, rather than being transferred from a Mini.
4. The same job signs nested code and the outer app with Developer ID and hardened
   runtime, retains Automation, submits to Apple, staples, and produces the public
   ZIP, SHA-256 file and source-bound `release.json`. Sparkle's bare `Autoupdate`
   executable must be signed before its framework using `Versions/Current/Autoupdate`,
   not a hard-coded version-A path. Then `scripts/publish-public-release.sh` verifies
   the extracted app, checks the exact source on GitHub and publishes through a
   draft without overwriting existing release bytes. The `--build-only` and
   `--sign-prebuilt` modes remain for explicitly requested local packaging; they
   are not a personal-machine fallback for the automated release.
5. Only after the public ZIP works, update README, setup/build guidance and the Pages site to
   point to the verified download. A source change to the native app also needs the separate
   five-second warned local install/restart and live PID, CDHash, signature, entitlement and
   rollback checks in `AGENTS.md`.

## Hosted signing credentials

Provision these encrypted repository Actions secrets before enabling the hosted
release workflow:

- `APPLE_CERTIFICATE_P12_BASE64`: the Developer ID Application certificate and its
  matching private key exported as password-protected PKCS#12, then base64-encoded.
- `APPLE_CERTIFICATE_PASSWORD`: the password protecting that export.
- `APPLE_ID` and `APPLE_TEAM_ID`: the Apple account and team used for notarization.
- `APPLE_APP_SPECIFIC_PASSWORD`: a separately labelled Agent Flow notarization
  password created at [account.apple.com](https://account.apple.com/).
- `SPARKLE_ED25519_PRIVATE_KEY`: the existing Sparkle key matching `SUPublicEDKey`.

Base64 is encoding, not encryption. Never commit or print these values, include
private keys in release artifacts, or rotate the updater key merely to migrate
runners. The Apple app-specific password authorizes notarization; it does not sign
the executable or replace the Sparkle key. Its label permits separate revocation,
not a per-app restriction enforced by Apple. Reuse the credential for future
releases; changing the main Apple Account password revokes all app-specific passwords.

The hosted setup creates and unlocks a randomly passworded temporary Keychain,
imports the signing identity and existing Sparkle key, stores the `ReleaseCI` profile
there and uses that explicit Keychain for every notarization command. It validates
credential access before the expensive build. Do not use Ethan's login Keychain,
copy the Mac login password into automation, or install a personal runner.

See [GitHub's signing-secret and temporary-Keychain procedure](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
[Apple's app-specific-password instructions](https://support.apple.com/en-gb/102654)
and [Apple's notarization authentication guidance](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).
A missing secret or failed hosted test blocks publication. Require the actual
release job, published download and installed updater checks before reporting the
complete system operational.
