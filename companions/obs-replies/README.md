# OBS spoken replies (optional, source installation)

After a Codex spoken reminder finishes, read the next15 seconds from OBS's
already-running microphone recording. Transcribe that bounded window using
Agent Flow's current live model, then let the original chat judge an obvious
reply. For example: a spoken question ends, you answer aloud, and that chat
briefly acknowledges what it heard.

This is an advanced companion for the shared Codex notification/question speech
integration. It is **not enabled by the normal Agent Flow download**, a new
microphone recorder, or a generic plug-in for every TTS application. Set it up
only when the user explicitly wants post-reminder OBS listening.

## Requirements

- macOS, Python3.11 or newer, FFmpeg/FFprobe, and the packages in `requirements.txt`.
- The existing `speak-action-reminder` and `question-reminders` skills/shared
  speech queue, including the passive `codex_voice_gate` helper. The installer
  checks exact known integration anchors and refuses an incompatible version.
- OBS WebSocket v5 already enabled, recording locally to MKV. The companion
  uses a loopback connection and read-only requests; it never changes OBS.
- A verified microphone track and a different recorded system-output track
  containing the spoken reminder. Track names are checked against the current
  file and live routing; no fixed Track3 assumption is built into the code.
- Agent Flow's current effective Mode uses `gpt-live-transcribe`, with its
  existing local-build OpenAI credential. Other providers fail closed; there
  is no silent model substitution or captured-selection prompt.
- For replies after a completed message: the existing Agent Bridge Codex
  channel. It resumes only the exact originating local chat.

Ask your agent to follow [AGENT_SETUP.md](AGENT_SETUP.md). Keep private settings,
device identifiers, OBS passwords, recordings and transcript receipts out of Git.

## Timing and behavior

1. The actual audio child's exit callback records wall time and shared system
   uptime, before media-resume bookkeeping and the completion sound. A skipped,
   cancelled, interrupted or failed announcement opens no reply window.
2. A local waveform match finds the played TTS tail in OBS's system-output
   track. This checks the recording clock rather than assuming the MKV filename
   or an encoder's counter is an exact audio timestamp. Ambiguous matches stop.
3. Only the next15 seconds of the verified mic track are sent to the configured
   transcription provider. OBS system-output audio stays local. There is no
   guessed question/selection context supplied to speech recognition.
4. New dictation, a Codex Voice call, a newer admitted announcement, a new typed
   reply, resolved question, changed recording/microphone/mixer or sleep/clock
   discontinuity prevents stale delivery. Other sources nominally routed into
   the mic track must remain silent throughout the window.
5. An acknowledged empty transcript is no speech; a provider error is a failure.
   Echo/repetition is screened before routing. Other nonempty transcripts remain
   **untrusted candidates**: the agent adopts only a clear reply to that specific
   spoken message. A15-second clip can end mid-sentence; do not invent the rest.

“Exact” here means an observed child-exit timestamp and alignment in the recorded
audio. Matroska timestamps have their own resolution (typically1ms). Physical
speaker/Bluetooth latency is not measured, and no acoustic timing guarantee is
claimed. A reference mismatch or incomplete window produces no inferred answer.

Extraction reads a small header and an adaptive, capped64MiB tail. It never
scans, copies, stops or remuxes the whole live recording. Waiting for actual
recorded bytes uses a filesystem event, not a fixed settling sleep. Each worker
is bounded; no LaunchAgent, cron job or idle polling loop is installed. OBS audio
meter events are subscribed only for that finite attempt.

## Returning the reply

- **Question reminder:** place a candidate under the existing question's
  `reply-windows/` directory. The asking agent checks it while already waiting;
  this does not start a second agent turn or answer a formal question card.
- **Completed-message reminder:** queue a labelled candidate through Agent
  Bridge to the exact originating chat. Its existing ownership guard normally
  requires120 seconds of rollout quiet before resuming that chat; do not disable
  that safeguard silently. The Desktop view may need reopening to show an
  externally started turn. Measure this on the installed Codex version.
- Only an obvious, complete, related reply may lead to an acknowledgement or
  further authorized work. Background speech, another assistant's conversation,
  uncertainty, silence and failed transcription cause no action or new speech.
- This never substitutes for a required written approval, credential, purchase,
  deletion, permission grant or physical/user-only confirmation.

The normal latency includes the requested15-second window, any actual mux flush,
and the provider's response. A synthetic15-second `gpt-live-transcribe` trial
completed in about6.4s after submission, with both its beginning and final phrase
intact; this is one measurement, not a service guarantee. Completed-message
routing has the additional existing ownership delay described above.

## Validation boundary

The Mini's integrated speech/companion checks and real full-duration provider
probe passed. A real user reply was recovered from the growing OBS recording.
That recovery was manual: fully automatic waveform-aligned capture and visible
conversational return still need live acceptance. Keep this advanced companion
opt-in; do not describe automated fixtures or installation as physical acceptance.

## Local files and disabling

Private configuration: `~/Library/Application Support/AgentFlow/OBS Replies/settings.json`.
Set `enabled` to `false` to stop new attempts and invalidate pending ones. Normal
speech, Agent Flow and OBS keep working. The shared queue's optional hook remains
inert while the extension is disabled or unconfigured.

The source installer creates a versioned runtime copy and backs up every shared
speech file it changes. It installs no native app and restarts nothing. Receipts
and machine transcripts stay in the private configured state directory; microphone
PCM is held only in memory, and the temporary generated-TTS reference is removed
after each attempt. Source MKVs and Agent Flow's saved recordings are untouched.

## Development checks

Run the focused tests on the project's required test machine:

```sh
python3 -m unittest -v test_obs_replies test_mkv_window test_audio_anchor test_speech_hook test_worker
```

Also run the existing speech FIFO, audio deadline, recording-lease and immediate
question suites against isolated integrated copies. Fake/fixture checks do not
prove an audible reply, a Desktop update or real background chat delivery.
