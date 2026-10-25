# GPT Live silence sleep

## Candidate status

The ten-second policy is held on `codex/agentflow-idle-sleep`. Build 461 was rejected
after reported focus interference and doubled typing during live settings inspection;
the exact build 460 was restored. Ethan explicitly requested source/test iteration
with Claude and no installation. Native tests and code review do not establish the
cause of that incident or authorize deploying this candidate.

## Behavior

`Audio → Recording Behavior → Sleep GPT Live During Silence` is an opt-in
setting for OpenAI `gpt-live-transcribe`. It is read when that recording creates
its realtime session, including when a typing-only recording first enables its microphone.

The microphone and complete WAV keep recording. After ten seconds of clearly quiet
audio and ten seconds without words, typing, or accepted selection/screenshot, Agent Flow
can stop appending audio to the existing realtime connection. A small moon on
the recorder waveform means the network stream is sleeping; recording continues.
Sound or session activity wakes it on the next audio callback. Recent audio is
buffered and sent before the waking chunk, preserving the beginning of the sound.
Stop still makes one commit and one final delivery through the existing route.

This is a conservative level detector, not speaker identification. Audible music,
other voices, or a noisy room can keep it awake. It does not promise to remove
background music, or prove that every extremely faint utterance can be detected.
The WAV is always retained for the existing History/retranscription path. Manual
Pause continues to stop capture separately and does not become this network mode.

The current timings and thresholds have one owner:
[`RealtimeSilenceSleepGate.Configuration.gptLiveDefault`](VoiceInk/Transcription/Streaming/RealtimeSilenceSleep.swift).
Only already-quiet frames update the noise estimate, so sustained detected speech
cannot gradually become its own noise floor. Invalid odd-byte PCM framing disables
omission for the session, preserving the downstream resampler's sample alignment.

## Billing and connection evidence — 24 October 2026

Synthetic speech was sent to the actual OpenAI transcription WebSocket using
`gpt-live-transcribe`, English, `delay=xhigh`, no automatic turn detection, and
exactly one final commit. Each run contained these two synthetic phrases:

> The silver bicycle waits beside the river.
> Seven orange balloons drift above the quiet garden.

| Probe | Audio sent | Provider-reported billed seconds | Final phrases |
| --- | ---: | ---: | --- |
| 15-second gap sent as silence | 20.9608 s | 21 | Both exact |
| 15-second gap with no appends | 5.9608 s | 6 | Both exact |
| No appends, boundary margins retained | 7.4608 s | 8 | Both exact |
| Five-minute no-append gap, margins retained | 7.4608 s | 8 | Both exact |

The five-minute-gap session lasted 329.18 seconds in total and emitted live text
before the final commit. This demonstrates that these no-append gaps did not add
billed audio time. It does not establish every future server idle limit or a
monthly saving: actual savings depend on how much clearly quiet audio is omitted,
and separate concurrent sessions each have their own transmitted audio.

A separate quiet-speech test mixed synthetic speech at −62 dBFS RMS with a
−60 dBFS background tone. OpenAI recognized the full input; the original
−50 dBFS / 9 dB detector omitted the phrase. The revised conservative detector
forwarded that entire fixture byte-for-byte. A lower-noise fixture omitted
200,320 of 576,000 input bytes while retaining every byte of the speech interval.
These synthetic checks are not physical acceptance with every microphone.

## Failure handling and diagnostics

Intentional quiet omission has separate `withheldChunks`/`withheldBytes` metrics;
it is not a queue drop. Real dropped audio, an incomplete drain, or a provider
failure rejects the realtime final and preserves the completed-WAV fallback.
An error after the drain check is checked again before returning a final.

`Streaming silence sleep summary` logs sent/withheld duration and counts.
`OpenAI completion usage` logs only whitelisted numeric usage fields and a known
usage type. Neither diagnostic includes audio, transcript, prompt, or item IDs.

Regression coverage is in
[`RealtimeSilenceSleepTests.swift`](VoiceInkTests/RealtimeSilenceSleepTests.swift),
alongside the existing streaming reliability, Primary/Next, and HUD-only guards.
