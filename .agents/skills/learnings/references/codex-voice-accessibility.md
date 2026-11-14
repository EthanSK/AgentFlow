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

Preserve the distinction between a request, readable state, posted shortcut and
audible behavior. The microphone and output commands use the same shortcut
sender, but microphone's paired fallback and speaker's live-control requirement
are different accepted policies. Do not remove that speaker requirement or
lengthen the existing read deadline merely because the exposure candidate failed.
H Chat's explicit audio-command path additionally uses longer reads and focus
recovery; copying those actions into recording startup is not an accepted fix.

Reconsider this mechanism only with new version-specific proof that the exact
host supports exposure and real Start/Stop state remains readable without focus
changes. See the matching 2026-11-14 entries in `LEARNINGS.md` and
`FAILED_APPROACHES.md` for the evidence and acceptance limits.
