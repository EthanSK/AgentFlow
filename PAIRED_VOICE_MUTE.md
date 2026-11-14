# Paired-Mac ChatGPT Voice microphone suppression

When Agent Flow opens its microphone on one Mac (the **source**), it can ask other Macs you
explicitly list (the **recipients**) to apply the same ChatGPT Voice microphone suppression
Agent Flow already applies locally. Releasing or pausing capture ends only the suppression that
capture owns. Typing-only sessions never open the microphone and request nothing.

Validation: build 491 passed 74 named focused tests in 11 suites and all 874 release tests in
41 suites through Xcode's normal test action on the Mac Mini, at source commit `3884b86f`.
The universal Developer ID signed, notarized and stapled public ZIP passed its downloaded
checksum and signature checks. The same build is installed and running on the MacBook source
and M1 recipient, with existing microphone settings and keyboard bindings unchanged.
The configured Agent Bridge endpoint returned the recipient's readiness answer. Natural
recordings from the installed source app also received acquire/renew/release replies, proving
that app-originated transport works for this pair. Refreshing the M1's stale Accessibility grant
made its running recipient answer `ready`; the saved requirement now matches the installed
Developer ID app. A natural recording returned `mutedUnverified` and `restoredUnverified`, and
Ethan confirmed that the M1's Voice is muting. He also confirmed the inherited unreadable-state
toggle limitation: an already-muted call can be inverted. This is not state-aware acceptance;
manual-mute preservation and independently verified restoration remain open. A text-only private
OpenAI feature request for a supported current-call state query, explicit microphone/output mute
setters and change events was accepted on 2026-11-08. That submission is not an implemented
state-control API or a promise of an individual response. See
[Acceptance checklist](#acceptance-checklist).

## How it works

```
source Agent Flow                                   recipient Agent Flow
-----------------                                   --------------------
Recorder start/resume ─► ChatGPTVoiceCaptureMuteCoordinator.prepareForCapture
                           ├─ local suppression (unchanged)
                           └─ PairedVoiceMuteBroadcaster (non-blocking)
                                └─ /usr/bin/ssh (Agent Bridge pairing, BatchMode)
                                     remote: exec /usr/bin/nc -U … VoiceMute/v.sock ─► PairedVoiceMuteReceiver
                                     stdin:  one JSON request line                       └─ same coordinator,
                                     stdout: one JSON response line                         paired owner
```

- **One mechanism.** The recipient's own running Agent Flow applies the request through its
  existing `ChatGPTVoiceCaptureMuteCoordinator`: the same snapshot, the same PID-targeted
  `realtimeVoice.toggleMicrophoneMute` command, the same read-only state checks and the same
  Accessibility permission. No helper, shell interpreter or new permission owner runs on the
  recipient. The one difference is which key posts that command: the recipient uses the binding
  it already has for it (see [Setup](#setup)), and a mute's inverse always uses the binding that
  posted the mute. Both boundaries require the same exact local Voice call for a mute and its
  inverse. If the call changes or cannot be identified, the old suppression is never restored
  onto a replacement call. A readable muted control belongs to the user.
- **Owners, not toggles.** A paired capture is one more owner of the recipient's suppression.
  Suppression is attempted when an owner begins (no-op if already owned) and restoration runs
  only when the last owner ends. A paired release therefore never unmutes ChatGPT under the
  recipient's own live capture, and the recipient's local stop never unmutes it under a paired
  capture.
- **Transport is Agent Bridge's pairing, not its messaging.** Agent Flow reads
  `~/.agent-bridge/config` read-only and applies Agent Bridge's own endpoint rule
  (`internet_host`/`internet_port` when set, otherwise `host`/`port`; `identity_file`, then
  `key`). It runs `/usr/bin/ssh` with a **constant** remote command; the request travels on
  stdin, so nothing from the request or settings is ever interpolated into a remote shell or
  process arguments. It sends no agent message, wakes no agent and spawns no agent.
- **Never on the user path.** Requests are recorded synchronously in capture order and sent in
  the background. An asleep, unreachable or slow recipient cannot delay the start sound, AUHAL,
  stop, paste or transcription. Remote suppression therefore starts in parallel with local
  preflight and can lag the start sound by the SSH round trip.
- **No forwarding.** Requests received from another Mac are never re-sent, so two Macs that
  list each other cannot loop. A request whose source is this Mac (an Agent Bridge alias that
  resolves back to itself) is rejected as `loopback`.

## Setup

Requirements on every Mac involved:

1. The Agent Flow build that contains this feature.
2. An Agent Bridge pairing **from the source to the recipient**: the source's
   `~/.agent-bridge/config` has a section for the recipient, and the recipient authorises the
   source's Agent Bridge key (what `agent-bridge pair` sets up). Check from the source with
   `agent-bridge status <recipient-name>`.

On each **recipient** Mac (the one whose ChatGPT Voice should be muted):

1. ChatGPT's microphone command has a keyboard binding in `~/.codex/keybindings.json`. Keep the
   one you already use; Agent Flow reads this file and never edits it:

   ```json
   {"command":"realtimeVoice.toggleMicrophoneMute","key":"<your shortcut>"}
   ```

   The key must be a function key (F1–F20), or a letter or digit held with at least one of
   Command, Control or Option. The command must have one shortcut, and that shortcut must not also
   be bound to a different command. Otherwise the probe answers `shortcutUnsupported` and the Mac
   is not toggled.

   This applies only to requests from other Macs. That Mac's **own** recordings still mute its
   Voice only with the exact local binding `Command+Control+Option+Shift+F20`, as before.
2. Agent Flow has Accessibility permission (already required for pasting).
3. Opt in:

   ```sh
   defaults write com.ethansk.VoiceInkPlusPlus VIPPPairedVoiceMuteReceiverEnabled -bool true
   ```

On each **source** Mac (the one you speak into), list recipients by their Agent Bridge machine
names. List only Macs; never list every pairing. Aliases of the same Mac are harmless (the second
delivery is treated as a renewal) but unnecessary.

```sh
defaults write com.ethansk.VoiceInkPlusPlus VIPPPairedVoiceMuteRecipients -array "<recipient-name>"
```

Both settings are read per request/capture. If a running Agent Flow does not pick up a change,
quit and relaunch it when it is idle (never during a recording or transcription).

To turn it off: on the source,
`defaults delete com.ethansk.VoiceInkPlusPlus VIPPPairedVoiceMuteRecipients`; on the recipient,
`defaults write com.ethansk.VoiceInkPlusPlus VIPPPairedVoiceMuteReceiverEnabled -bool false`.
While the recipient is off it still honours `release`, so an existing lease ends cleanly.

### Side-effect-free readiness probe

From the source, without recording and without touching ChatGPT:

```sh
printf '{"v":1,"op":"status"}\n' | agent-bridge run <recipient-name> \
  'exec /usr/bin/nc -U -w 4 "$HOME/Library/Application Support/VoiceInkPlusPlus/VoiceMute/v.sock"'
```

The JSON line in the output is the answer (`agent-bridge run` can print its own status lines
around it):

| Answer | Meaning |
|---|---|
| `{"v":1,"status":"ready","detail":"ready"}` | Opted in, usable shortcut binding, Accessibility granted |
| `…"detail":"shortcutMissing"` | Opted in, but `realtimeVoice.toggleMicrophoneMute` has no binding |
| `…"detail":"shortcutUnsupported"` | Opted in, but the binding can't be trusted: an unsupported key, several shortcuts, shared with another command, or the wrong key on this keyboard layout |
| `…"detail":"accessibilityMissing"` | Opted in, but Agent Flow lacks Accessibility |
| `{"v":1,"status":"disabled"}` | Recipient has not opted in |
| no JSON line, `nc` error | Recipient's Agent Flow is not running, is an older build, or the Mac is not macOS |

The probe runs from your terminal. Agent Flow's own SSH connection is made by the app, so
also confirm a real recording in the logs below (see Local Network note).

## Logs

```sh
log show --last 10m --info --predicate 'subsystem == "com.ethansk.VoiceInkPlusPlus" AND (category == "PairedVoiceMute" OR category == "PairedVoiceMuteReceiver" OR category == "ChatGPTVoiceCaptureMute")'
```

The source logs every delivery with its public `seq` and `session` prefix; the recipient logs
`Paired capture acquired|released` with the same values and its observed `outcome`. Recipient
names are logged as private values; hosts, users and key paths are never logged. Only a
`status=` line from the recipient proves it processed a request. `unreachable` means the request
was not delivered; `timed out` and `gave no Agent Flow answer` mean the remote outcome is
**unknown**, never success.

## Lifecycle, ordering and races

Each source app launch mints a random source ID; each capture lease (start/resume until
pause/stop) gets a session ID; every request carries a sequence number assigned in capture order.
The recipient keeps, per source, the highest sequence seen and at most one live session.

| Situation | Behaviour |
|---|---|
| Start/resume | `acquire` to each listed recipient; the only request that can post the shortcut |
| Pause/stop | `release` for that session only; recipient restores only if it was the last owner |
| Stale local release (an older capture generation) | Not forwarded; the local coordinator ignores it too |
| Quick start→stop, release arrives first | Late `acquire` has a lower sequence and is dropped: no mute |
| Duplicate/retried delivery | Not newer than the last sequence: `stale`, no effect |
| Late release of an older session after a newer capture | `stale` or `unknownSession`; the newer capture stays muted |
| Newer capture from the same source without a release | Replaces the older session in one step, no restore/re-mute pair |
| Recipient's own Agent Flow capture overlaps | Both are owners; restoration waits for the last one |
| Two source Macs | Independent owners; restoration waits for both |
| Long recording | `renew` every 30 s extends a 90 s lease; it reads no ChatGPT or Accessibility state |
| Source sleeps, loses network or crashes | Renewals stop; the recipient ends that owner when the lease expires and restores through the normal checks |
| Release never arrives | Same lease expiry |
| Recipient unreachable at start | Logged; local recording unaffected; no automatic re-acquire later in that recording |
| Recipient Voice visibly muted by the user at start | Not toggled, not owned |
| Recipient Voice visibly unmuted by the user before stop | Ownership relinquished without a toggle |
| ChatGPT process replaced or Voice session ended | Ownership discarded without a toggle |

## Known limits (not proven by the supported interface)

- **Unreadable state keeps build-412 semantics.** When ChatGPT's background control is unreadable,
  the recipient uses the same accepted paired-toggle fallback as local capture. Its known risk
  applies there too: a call that was manually muted while unreadable can be inverted. This is not
  state reconciliation. The refusal-only build 413 was withdrawn because muting stopped working,
  and that policy is deliberately not reapplied here.
- **Process identity is not call identity.** A new Voice call in the same ChatGPT process can
  receive the restoring toggle.
- **Only the F20 chord has been seen working.** The PID-targeted event has been accepted in
  practice with `Command+Control+Option+Shift+F20`. A recipient's letter or other function-key
  binding uses the same event path, but whether a backgrounded ChatGPT honours it is unproven until
  the acceptance checklist runs on that Mac.
- **Recipients without the local binding.** Such a Mac is muted for other Macs' captures but not
  for its own recordings, which keep the existing `F20` requirement. If its own capture overlaps
  a paired one, the paired mute still applies and is still restored.
- **Keyboard layouts.** A letter or digit is posted as a physical key position and checked against
  what the current layout types there. A mismatch is refused (`shortcutUnsupported`), including
  layouts that switch to QWERTY only while Command is held. If macOS reports no character, the
  standard position is used because nothing contradicts it.
- **Binding changes.** The binding is read for every toggle. Editing it to something unusable
  between mute and restore makes the restore fail as `shortcutFailed`; ownership is kept rather
  than claiming success.
- **Remote latency.** Suppression on the recipient follows the SSH round trip plus its own
  checks, so the first moment of speech can reach the recipient's Voice. Not measured.
- **Recipient restarts.** A normal Quit or update waits for remote capture ownership and its
  final restoration, just as it waits for local recordings. Pending outbound requests also
  hold that existing quit guard until their bounded work ends. Final idle Quit closes request
  admission atomically, so an arriving request cannot post a mute during exit. A crash or forced
  termination still loses ownership; the shortcut stays applied. A replacement instance answers
  renewals with `unknownSession` and never guesses by re-acquiring or toggling another call.
- **Expiry timing.** A vanished source's suppression ends up to 90 s after its last successful
  acquire/renew, counted while the recipient is awake. The timer is expected to stop during the
  recipient's own sleep (not measured), so a release missed while it slept can leave Voice muted
  for the rest of the lease after it wakes. Neither the lease nor the renewal adds a wait to
  recording or finishing.
- **Local Network privacy.** SSH is spawned by Agent Flow, so macOS may attribute a LAN
  connection to Agent Flow and require Local Network permission. Agent Flow has no
  `NSLocalNetworkUsageDescription`. Verify a real delivery on each endpoint type in use; a denied
  connection is logged as unreachable.
- **Host keys.** Agent Flow mirrors Agent Bridge's SSH policy (`StrictHostKeyChecking=no`,
  `UserKnownHostsFile=/dev/null`) and adds `BatchMode=yes`; it does not add stronger host
  verification than the pairing already has. `~/.ssh/config` still applies (Tailscale proxy).
- **Receiving endpoint.** The recipient socket is bound whenever Agent Flow runs; acquire/renew
  are refused unless opted in. Any process running as the same user can reach it, which is no
  more than that user's own Agent Bridge pairing already grants.
- **No UI.** Configuration is by `defaults`; outcomes are in logs only.
- **Not macOS:** other operating systems produce no answer and are logged as unknown.

## Protocol

One JSON line each way, at most 512 bytes, protocol `v: 1`.

```json
{"v":1,"op":"acquire","source":"<uuid>","seq":12,"session":"<uuid>","lease":90}
{"v":1,"op":"renew","source":"<uuid>","seq":13,"session":"<uuid>","lease":90}
{"v":1,"op":"release","source":"<uuid>","seq":14,"session":"<uuid>","lease":90}
{"v":1,"op":"status"}
```

Responses: `{"v":1,"status":"…","detail":"…"}` where `status` is one of `acquired`, `renewed`,
`released`, `stale`, `unknownSession`, `disabled`, `rejected`, `ready`, and `detail` is a fixed
outcome name (`mutedVerified`, `mutedUnverified`, `alreadyOwned`, `alreadyMuted`, `noChatGPT`,
`noActiveVoice`, `shortcutFailed`, `restoredVerified`, `restoredUnverified`, `heldByOtherCapture`,
`userUnmuted`, `voiceEnded`, `processChanged`, `notOwned`), rejection reason (`malformed`,
`loopback`, `capacity`, `shuttingDown`) or, with `ready`, a readiness value (`ready`, `shortcutMissing`,
`shortcutUnsupported`, `accessibilityMissing`). Leases are clamped to 15–300 s. The recipient
tracks at most 16 sources and serves at most 4 connections at once.

Code: `VoiceInk/Services/PairedVoiceMuteProtocol.swift` (wire format, ledger, settings),
`PairedVoiceMuteBroadcaster.swift` (source, Agent Bridge resolution, SSH),
`PairedVoiceMuteReceiver.swift` (recipient socket), `ChatGPTVoiceShortcut.swift` (binding
validation), `PairedVoiceMuteActivity.swift` (quit protection and request admission) and the owner
set in `ChatGPTVoiceCaptureMuteCoordinator.swift`. Tests:
`VoiceInkTests/PairedVoiceMuteTests.swift`.

## Acceptance checklist

Use a disposable Voice call. Record results in `LEARNINGS.md` only after they are observed.

1. Readiness probe answers `ready` from each source to each recipient.
2. Recipient call listening; source starts recording → recipient Voice mutes; source stops →
   recipient Voice unmutes. Logs on both sides show the same `seq`/`session`.
3. Source pause → recipient unmutes; resume → mutes again.
4. Recipient call muted by hand (visible control) → source recording leaves it muted.
5. Recipient also records locally while the source records → recipient stays muted until both
   stop, in either stop order.
6. Recipient asleep or offline → source start/stop/transcription unchanged; log shows
   `unreachable` or unknown, never success.
7. Source lid closed mid-recording → recipient restores within about 90 s.
8. Typing-only session on the source → no paired request in the logs.
9. Background (unreadable) recipient control → note whether mute and restore both happened.
10. Recipient whose binding is not the F20 chord → steps 2 and 3 pass with ChatGPT in the
    background, and `~/.codex/keybindings.json` is byte-for-byte unchanged afterwards.
11. That same recipient records on its own, with no paired capture → its Voice is not toggled and
    its recording is unaffected.
