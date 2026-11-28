# Codex Voice controls and exposure

## Current requested recording policy — 2026-11-28

Ethan asks recording to preserve the current state: if H Chat or Ethan already
silenced Voice speakers or muted the microphone, leave that control alone.
Treat each channel separately and pair only a recording-owned attempt on the
exact same call. A later readable unmute takes precedence. An unreadable state
is never permission for a blind toggle or inverse. This supersedes the 24 November
Agent Flow direct-toggle/reader-OFF policy; H Chat's explicit commands stay separate.

Use bounded, background reads of existing controls. Keep the unsupported exposure
preparation dormant, no focus/AXPress/pointer changes, no polling or retry toggles.
Preserve the existing 300ms speaker-to-microphone gap and recheck local/paired
ownership and current state after it. A missing preference enables the reader;
an explicit false still skips it and leaves the state unknown.

Shortcut dispatch is not applied-state confirmation. Codex's UI can lag, and a
snapshot cannot attribute an unseen external mute/unmute/mute sequence. Do not
claim atomic cross-app ownership or audible acceptance from these checks. If
state is unreadable at restoration, discard the lease without an inverse; this
can leave Voice muted until it is restored explicitly. Stronger provenance needs
a supported state/change feed or an agreed shared ownership interface, not a
blind fallback. Verify installed code and real-use acceptance separately.

## Earlier 24 November policy (superseded for Agent Flow recording)

On 2026-11-24 Ethan explicitly chose to leave Agent Flow's microphone/UI-state
reader OFF. `VIPPVoiceMicrophoneStateReadsEnabled` is false when absent. Gate both
AX entrypoints, the post-toggle readback wait and launch/activation exposure
observers. Keep the parser dormant for a future explicit enable; do not restore
read-first behavior from the older investigation below. No settings UI is added.

Normal capture pairs direct speaker/microphone toggles on the same call, with the
requested 300 ms speaker-to-microphone gap. Recheck pending local/paired ownership
after that suspension. No duplicate toggles or blind retries. Direct dispatch
cannot identify a manually muted starting state or prove native audio acceptance.
This Agent Flow policy does not change H Chat's independent explicit controls.

## Earlier exposure investigation

Ethan approved one scoped `AXManualAccessibility=true` request for the exact
configured Codex Voice host on 2026-11-14. This does not broaden the separate
VS Code selection-capture exception. Keep it ahead of capture, off the main
thread and at most once per process birth; do not retry an unsupported result,
toggle exposure off, request enhanced UI, change focus or post audio input.
Test hosts must never prepare the user's actual Codex process.

The disposable Mini Electron fixture exposed a web area about two seconds after
one successful request while remaining backgrounded. A hidden fixture did not
expose its renderer within six seconds. Neither result proves live Codex support.
Installed build511's request returned `-25205` (`attributeUnsupported`); later
real capture found either one node/no Voice controls, or an End control at Start
followed by no live control before the existing Stop read deadline.

H Chat's explicit audio commands independently send the configured native toggle
without a button read or focus change. Automatic Agent Flow Voice recaps were
removed at Ethan's request on 2026-11-24; recording diagnostics stay local and
must not reintroduce a recap-time control read or queue submission.

Reconsider this mechanism only with new version-specific proof that the exact
host supports exposure and real Start/Stop state remains readable without focus
changes. See the matching 2026-11-14 entries in `LEARNINGS.md` and
`FAILED_APPROACHES.md` for the evidence and acceptance limits.

## Recording speaker shortcut

Ethan requested direct dispatch on 2026-11-24. While recording speaker control
is enabled, resolve the configured Codex Voice output shortcut and send it once
to the exact active call, even when another chat is selected. A successful post
owns one paired toggle on the same call. Preserve the recording lease and stop
ownership after the restore attempt. The start/stop dispatch uses no speaker
control scan, mute-state check, focus change or retry.

The microphone keeps exact-call metadata and ownership. Manual-state protection
through a readable control is available only when the dormant reader is explicitly
enabled. Keep shortcut posts distinct from observed mute state and audible behavior.
