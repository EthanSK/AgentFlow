# Codex Voice controls and exposure

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

The microphone keeps its own snapshot and manual-state protection. Keep a
speaker shortcut post distinct from observed mute state and audible behavior.
