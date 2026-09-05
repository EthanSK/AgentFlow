# GPT Live Transcribe: context, quality, and evidence

Read before changing OpenAI transcription prompts, Vocabulary hints, language, delay,
session reuse, or quality claims. Research checked 2026-09-05. Re-fetch the cited model
documentation when changing its contract; this is a dated audit, not a frozen API manual.

## Identify the actual model

VoiceInk++ uses `gpt-live-transcribe` for microphone streaming, not a conversational
`gpt-realtime-*` voice agent. The [model page](https://developers.openai.com/api/docs/models/gpt-live-transcribe)
lists audio/text input, text output, and realtime transcription. It currently lists only
the same-name snapshot; do not invent a dated pinned model ID or assume an alias never changes.
The [Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)
recommends this model for incremental live text. `gpt-transcribe` is the separate
completed-audio fallback; moving it into streaming does not give the same incremental behavior.

Verify the installed bundle and decode `modeConfigurationsV2`, not only global preferences.
The 2026-09-05 installed build-322 audit found all seven enabled Modes selecting English
`gpt-live-transcribe`, realtime enabled, and AI enhancement disabled. The static prompt
contained one whitespace character and normalized to absent. Optional recent context was on.
These are observed settings, not universal defaults or permission to change another install.

## Keep the three context fields separate

The [transcription quality guidance](https://developers.openai.com/api/docs/guides/transcription#improve-transcription-quality)
distinguishes these inputs and says context should be relevant to the recording, without
repeating the transcription task. It does not prescribe an optimal number of messages or
keywords, or promise that filling the available budget improves recognition.

| Input | Supported purpose | VoiceInk++ boundary |
| --- | --- | --- |
| `prompt` | Topic or setting of the audio | Static context first; optional bounded active-Codex suffix; no History fallback |
| `keywords` | Literal names, acronyms, and other terms that may be spoken | Frozen user Vocabulary only; independent of the prompt budget |
| `languages` | Expected input languages | Frozen Mode language; `en` for the audited install; omit for auto |

Keywords guide recognition; they are not text the model must insert. Do not promote words
from chats or an earlier imperfect transcript into the user's dictionary, duplicate the
dictionary inside `prompt`, or describe an omitted keyword as deleted user data. Current
normalization drops invalid/duplicate terms and stops at 100. That is a local cap, not a
verified published provider maximum. The earlier dictionary audit found all 82 stored terms
valid; the current trace still shows an 82-term snapshot on each sampled recording.

The [Realtime context contract](https://developers.openai.com/api/docs/guides/realtime-transcription#add-transcription-context)
rejects malformed keywords, including angle brackets and line breaks, and excessive prompts.
Use `languages`, not the legacy singular `language`, for these models. VoiceInk++'s observed
1,024-character rejection boundary and 992-character production cap are separate constants.
The guide fetched for this audit does not itself publish that numeric maximum: preserve the
earlier exact-boundary probe evidence and 32-character reserve, not an invented citation.
A successful short request cannot validate the maximum. Remove oldest whole context entries
before transport; never truncate encoded JSON or sacrifice Vocabulary to make a suffix fit.

## Do not turn recognition context into an agent prompt

Build 322 Codex selection kept up to four 160-character message prefixes from the proven
active task. The parser accepts user/assistant text but does **not** filter assistant
`channel`; commentary can consume slots intended to supply useful naming context.
Its wrapper, instructions, JSON keys, and role labels also consume the small prompt budget.
Exact task identity proves provenance, not relevance or recognition benefit.

In build 322, when exact Codex context was unavailable, History contributed up to three eligible excerpts,
320 characters each, within 15 minutes and one stable Mode ID. Budget fitting can retain
fewer. Same Mode is not same conversation, and a previous recognition error can be fed back
as a hint. Neither risk is proof of the cause of Ethan's reported errors. Do not silently
disable requested context, broaden its capture, or claim the existing counts are optimal.

Ethan approved the leaner policy on 2026-09-05. Build 323 keeps at most two recent user or
explicit final-channel assistant excerpts, each at most 160 characters with whole-word
truncation. Missing/unknown assistant channels and progress commentary are excluded.
Deduplicate repeated text across roles. A short topic label and JSON string array replace
XML, role objects, and extra instructions; quoting preserves structure, not instruction
priority. Retain useful code identifiers rather than deleting names the user may speak.
The optional block has an independent 400-character maximum; the complete prompt still
fits 992 with the normalized static prefix unchanged. Drop oldest whole excerpts if escaped
text expands beyond either limit. No Codex identity/context means static prompt plus frozen
Vocabulary only: no History query, summarizer, extra API call, or new delivery/AX path.
These are conservative engineering limits, not a measured optimum or a proven accuracy gain.
The old pure History policy and its comments/tests remain test-only negative evidence.
Post-fit `codexMessages`, `contextChars` and normalized `promptChars` describe what is sent;
`recentEntries=0` is retained for the existing privacy trace format, not a fallback.

JSON escaping protects the block's structure; the explanatory warning does not establish an
LLM instruction-priority sandbox or guarantee that quoted instructions are ignored. Prefer
testing a smaller relevant-context alternative over adding more admonitions, correction
rules, or examples. Transcription prompts are not guaranteed spelling/number formatters;
keep the rejected numeral-switch evidence in `FAILED_APPROACHES.md` in view.

## Tune the relevant latency control

`OpenAITranscriptionConfiguration.accuracyDelay` is already `xhigh`. The
[latency/accuracy guidance](https://developers.openai.com/api/docs/guides/realtime-transcription#tune-latency-and-accuracy)
describes increasing delay as providing more audio context, with a possible word-error-rate
benefit. It gives no universal milliseconds per level or guarantee of best accuracy on this
microphone. `delay` is not a chat model's reasoning-effort setting. Compare `medium` and
`xhigh` on real speech only after holding prompt/keywords/language constant; do not sell a
lower setting as an accuracy improvement or increase unrelated startup waits.

Keep 24 kHz PCM16 mono on the realtime wire and explicit commit at Stop. `turn_detection`
is currently null; changing voice activity detection changes turn ownership, not merely
word choice. The current 16-to-24 kHz resampler preserves callback continuity; upsampling
cannot reconstruct missing source detail. Do not change shared audio hardware or add
unverified noise processing during a prompt experiment.

## Audit requests separately from audio events and recognition

`OpenAIStreamingProvider.connect` sends one `session.update` for a recording. Subsequent
`input_audio_buffer.append` events carry audio chunks, not another copy of the prompt.
There is one explicit commit, then socket cleanup. Two `request context frozen` log lines
can come from provisional/final Mode resolution; they are not two network requests.
`StreamingTranscriptionSession` uses one recording-owned finalization task and may upload
the same WAV once through the fallback after an unusable live result. Do not add per-partial
prompt updates, automatic context retries, or permanent cross-recording sessions without
separate evidence for ordering, privacy, cancellation, and cost.

The guide's statement that earlier transcribed turns are automatic context explicitly
describes `gpt-transcribe` in a Realtime session. Do not generalize it into a guarantee of
cross-recording memory for `gpt-live-transcribe` or this app's fresh-session lifecycle.

The build-322 trace sample on 2026-09-05, 18:00–21:01 Europe/London, contained 87 starts and
87 connections: 42 selected Codex context, 21 History, and 24 no effective prompt. There
were 174 local context-resolution log lines. Prompt lengths were median 704, p95 984, max
990; a logged raw length of 1 here means whitespace that transport omits. Logged entry
counts precede whole-entry budget fitting, so they are not final included-message counts.
All 87 drains contained audio and reported zero dropped chunks. Connection median/p95 was
0.795/2.067 seconds; stop-to-live-final median/p95 was 0.687/0.861 seconds.

80 live finals were nonempty; seven were empty and took the completed-file fallback.
Those seven retained WAVs had measurable but quiet audio (mean -50.4 to -41.9 dBFS). This
does not prove speech was present or that capture/model quality failed. Do not equate
nonzero PCM, an HTTP success, a fluent transcript, or a pipeline error string's nonzero
`finalChars` with correct recognized speech. Check pipeline status first. No streaming
event error or explicit rate-limit marker appeared in this filtered sample; it is not an
account usage/billing audit and cannot prove every request was accepted.

## Evaluate before recommending a new strategy

Use the [official evaluation checklist](https://developers.openai.com/cookbook/examples/migrating_from_whisper_to_gpt_transcribe#9-evaluate-before-and-after)
with identical representative audio and human-checked reference text. Compare the current
payload with dictionary-only and a short relevant-context variant while keeping model,
language, audio and delay fixed. Then vary delay separately. Include disputed names, short
commands, numbers, corrections, ordinary prose, silence/background sound, and long speech.
Measure word errors, exact terms, unspoken keyword insertions, omissions, empty results,
first delta, stop-to-final latency, and fallback frequency separately. Repeat close cases;
do not derive accuracy from transcript agreement, length, synthetic speech alone, or the
catalog's decorative `accuracy: 0.98` value. GPT Live supplies no confidence scores, word
timestamps, or speaker labels according to the fetched guide.

No paired human-reference quality comparison was completed in this audit. Recommended
next experiment: keep the dictionary and English hint; compare the previous four-message
context with no optional context and with the approved compact policy on identical audio.
The compact policy is an authorized implementation, not a proven cure. User-provided examples
are not a prerequisite: use existing saved recordings with human-checked reference speech.
Do not upload a private corpus
to another provider or start a large billable run without task-specific authorization.
Keep reports private and prompts, audio, chat text, and dictionary contents out of logs.

Preserve `RecentTranscriptContextTests`, `CodexConversationContextTests`, frozen
realtime/fallback parity, Primary/Next isolation, and HUD-only partials for an implementation.
The synthetic provider probe validates protocol acceptance, not human recognition quality.
Comments/research alone do not require a rebuild or an unnecessary restart of the signed app.
