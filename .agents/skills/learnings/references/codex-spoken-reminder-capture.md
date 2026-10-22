# Codex speech and recording priority

User-requested — 2026-10-09: do not play Codex text-to-speech while Agent Flow records. Replace live Potential ignore annotation with skipped speech and an immediate written notification, without waiting or replaying the speech later. Preserve every captured word, manual Pause, audio settings and normal recording.

## Current contract

- The shared speaker checks once before media coordination, allowing at most 0.5 seconds for the transport acknowledgement, and skips immediately when busy or unconfirmed; it does not retry after recording ends. Voice pending-start, recording and manually paused voice capture block it. Microphone-off typing may admit speech, including a start reserved explicitly as typing. Unknown state blocks too; a genuinely absent app permits speech.
- Version 3 `idle-only` on the existing speechPlayback/ACK channels admits only a verified helper and parked audio child. The main-actor receiver reads microphone intent separately from the delivery barrier: typing owns delivery but not audio capture. Voice reservation, microphone enable and pause-resume revoke registered audio before the hardware await; heartbeats cover missing/reordered notices. A late Command during a voice-start hardware await is not proof of microphone-off startup.
- Only the reminder's own verified same-user PID incarnation and executable may be stopped. Never signal the recorder, another app, or change microphone volume.
- New recordings ignore old overlap snapshots and never create Potential ignore tags. Preserve legacy tag parsing/viewers and all saved content; the previous approximate annotation behavior is historical only.
- Final/question reminders retain FIFO, cancellation, media balance, voice assignments, level and deadline. A timed-out wait skips stale speech and its chime; normal written notifications remain.

## Verification

Use the actual Swift helper lifecycle tests and native CodexSpeechPlaybackTests: unknown/busy/idle, busy-to-idle, parked launch race, child revocation, unrelated child refusal, preserved PCM and legacy archives. Run mandatory Primary/Next and HUD-only guards. Test and sign on the Mini, install only after the user's live session ends using the five-second warning and cooperative quit veto. Automated checks are not proof of physical audibility.

User-requested — 2026-10-10: typing with Agent Flow but not recording voice must not block text to speech. Preserve `typingOnlyDoesNotOwnReminderCapturePriority`, `typingAdmissionSurvivesHeartbeatUntilMicrophoneEnable`, `microphoneEnableRevokesSpeechBeforeBothHardwareAwaits`, and `typingToggleReservesMicrophoneOffBeforeStarting`. Speech admission during typing is never permission to quit a typing session; installation still requires the all-session termination veto.
