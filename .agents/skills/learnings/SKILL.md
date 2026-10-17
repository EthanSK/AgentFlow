---
name: learnings
description: Preserve VoiceInk++ institutional memory, search rejected approaches, and normalize Ethan's mouse-button terminology. Use automatically before any bug fix, regression investigation, fragile behavior change, primary/thumb/toggle-button or Next/forward/Next Track work, paste delivery, live compatibility testing or tracing, and after any feature, fix, deployment, or investigation that produces durable verified evidence. Read TERMINOLOGY.md, search LEARNINGS.md and FAILED_APPROACHES.md, apply accepted contracts, record new evidence, and improve this skill when reusable workflow, terminology, safety, or validation changes.
---

# VoiceInk++ learnings

Compound verified project knowledge for Codex and Claude Code. Treat `LEARNINGS.md` as the dated evidence index, `FAILED_APPROACHES.md` as the mandatory negative-evidence ledger, and this skill as the reusable procedure that maintains both.

## Continuous improvement

Improve this skill as part of using it. Whenever use, debugging, feature work, deployment, investigation, or user feedback produces a durable verified finding, update `LEARNINGS.md` during the same task without waiting for a separate request. When real evidence rejects a plausible mechanism or exposes a repeated regression trap, also update `FAILED_APPROACHES.md` with the observed result and the narrow condition required before reconsideration. When a finding changes how future agents should gather, interpret, validate, or preserve evidence, update this skill's instructions, scripts, tests, or references too. Retest affected behavior and validate the skill before finishing. Preserve reusable evidence; never record guesses, duplicate guidance, secrets, credentials, or transient runtime state.

## Skill usage announcement

Tell Ethan when this skill causes an action or pause, and briefly explain which project safety or
validation contract applies.

## Start with prior evidence

Agent Flow must use Ethan's Scarlett 18i8 microphone. Warn him if another input
is selected or used, and ask for his approval before changing it or accepting a
changed input. Do not silently switch back to Scarlett either. Verify both the
saved input choice and the actual recording-device metadata; the system output
or a saved preference alone does not prove which microphone captured the audio.
This is an agent operating rule, not a continuously running microphone monitor.
User-requested, destination approved — 2026-10-17.

Never stop, quit, terminate, or restart Ethan's running Agent Flow while he is
mid-speech or in a recording session. Wait until his current session ends before
an install or restart, even when the build and tests are ready. A missing recorder
window or an apparently idle Accessibility snapshot is not proof that the session
ended; the recorder may be hidden or recovering. Monitor safely and continue the
authorized installation automatically when the current session finishes; do not
ask Ethan to confirm an ordinary session end. Use cheap read-only checks every
few seconds while this task is active, not repeated model turns or UI probes.
Require the installed app's `applicationShouldTerminate` all-session veto at the
final cooperative quit boundary: recording, typing, paused capture, transcription
and delivery all count as active. Give the real five-second restart warning,
recheck immediately afterward, and treat a refused quit as continued activity;
never escalate to TERM, KILL or another forced exit. Keep a bounded watcher, and
use the product's thread heartbeat only if continuation must survive yielding;
pause that heartbeat once installation is verified. Unknown identity/state is
not idle: preserve the app and candidate, and report a genuine verification
blocker instead. Do not turn a release deadline into a forced stop.
User-requested automatic safe installation — 2026-09-30; verified with the
guarded build-390 installation recorded in `LEARNINGS.md`.

For every local update, preserve rollback bundles as verified ZIP archives with
`python3 scripts/archive-local-rollback.py /Applications/AgentFlow.app`, following
the rollback section of `UPDATING.md`. Never leave dated launchable app backups in
Applications, Downloads, Application Support or agent outputs: macOS registers
bundle contents even when the folder is hidden or renamed `.bak`. Verify archive
extraction, build, executable checksum and deep/strict signature before retiring
the old copy; retain required checkpoints and never overwrite an archive. The
archive helper must not quit or replace the app, so the idle-only installation
contract above still applies. Cleanup uses exact reviewed paths and recoverable
Trash, not recordings/settings deletion or a global LaunchServices reset.
User-requested cleanup and recurrence prevention — 2026-10-06; see `LEARNINGS.md`.

1. Resolve the repository root and read its `AGENTS.md`.
2. Read the newest relevant entries in `LEARNINGS.md` and the matching rejected/superseded sections in `FAILED_APPROACHES.md`. For either mouse button, recording destinations, focus restoration, recorder UI, paste, or auto-send, read `TERMINOLOGY.md` and `RECORDING_DESTINATIONS.md` completely. For background insertion, auto-send, or verification, also read `BACKGROUND_DELIVERY_TEST_MATRIX.md`.
3. Search with one to three symptom or subsystem terms:

   ```sh
   bash .agents/skills/learnings/scripts/check.sh "<keyword>"
   ```

4. Inspect named accepted commits and current tests when a learning points to them. If `FAILED_APPROACHES.md` names the proposed mechanism, stop unless new evidence changes the exact recorded failure condition; write that distinction down before experimenting. Preserve verified contracts instead of recreating remembered behavior.
5. For a remembered historical rollback, never choose by version proximity or a version label alone. Correlate Ethan's timestamped acceptance/failure message with the immediately preceding verified install/restart, then require the artifact's build, CDHash or executable checksum, and delivery architecture to agree. Early build 203 was reused for materially different binaries, so its label is not an identity.
6. State any relevant prior constraint before making a risky change.

For the separate read-only Codex pane inspector, distinguish the clicked pane,
focused pane and editable-input status; Conversation-region focus is not a caret.
Use only reported/verified host-specific markers, bounded app-owned focus reads
and fresh same-window evidence. Preserve explicit partial-path evidence instead
of discarding it solely because an ancestor limit was reached; owner/focus changes
remain fatal. Test the model and fake adapter on the Mini, exercise Demo locally,
then leave Live for Ethan's own clicks. Never inspect its live Codex output as an
agent workaround, add descendant scans, or turn a diagnostic classification into
paste authority. Self-improved — 2026-10-17: the 24-ancestor/old-marker inspector
failed against the supplied 34-deep live path; 39 bounded regression checks and
the Demo body-click case validate the correction recorded in LEARNINGS.md.

For a missing prompt link or expanded-XML regression, compare the live recipient's
bundle URL, version and build with the compact-prompt classifier before changing
paste delivery. Recognize the known `com.openai.codex` desktop hosts `Codex.app`
and `ChatGPT.app` independently of release versions for presentation only; do
not extend exact-input/AX mutation allowlists. Test the production pipeline with
the installed host and an unknown future version, including the opening queued
link, concise footer, inline angular markers and every authored word. Compare
automatic and Won't paste output after normalizing only immutable archive paths;
first filter automatic output by its actual recipient: ordinary apps such as
Chrome, Safari, editors, terminals and unknown identities receive authored
speech/typing only, without prompt links, XML, timestamps or math. Only Codex,
Telegram and Claude Desktop have context overrides: local Codex hosts use compact
file links; both Telegram identities and `com.anthropic.claudefordesktop` retain
inline XML. Cloud ChatGPT, Slack, Discord and all other apps receive plain authored
speech/typing. Claude Code in an ordinary terminal/editor does not identify itself
as Claude Desktop; do not broaden those hosts automatically. Share the local
interpretation skill with Claude Code through a symlink to the existing Codex
skill directory, not a separately maintained copy. Local Code sessions load that
personal skill; cloud Chat/Cowork do not load a local symlink. User-requested
Claude exception and shared skill — 2026-10-17. Preserve raw/skip output. Do not infer local-file access from
presentation, a browser name or Tailscale connectivity. Clipboard
completion has no selected recipient and must never consult foreground focus.
Self-improved — 2026-10-01: the 12553 host update repeated the stale-presentation
gate failure despite generic/old-host coverage; see the host-update entries in
`LEARNINGS.md`, `FAILED_APPROACHES.md` and the native pipeline regression.
User correction — 2026-10-03: ordinary Chrome pastes must be raw authored text
by default. The 2026-10-01 local/unknown compact default accidentally overrode
that existing recipient filter. Keep presentation separate from context eligibility;
test both Telegram identities, ordinary/unknown apps and complete archives through
the production pipeline, not a classifier fixture that endorses the regression.

The keyword helper supports current `##`-headed entries and older delimited entries
after `(newest first)`. Retest both with `python3 scripts/test-check.py` from this
skill folder when changing its parser. Self-improved — 2026-09-27: the old parser
silently skipped all newer headings; mixed-layout and literal-keyword fixtures now cover it.

For upstream work, read `UPDATING.md` and treat upstream as a feature source, never a branch to merge wholesale. Audit in a disposable clone/worktree, obtain Ethan's approval for one user-visible feature, and manually port only that feature while preserving VoiceInk++'s destination, delivery, vocabulary, identity, and release guards.

For public setup changes, keep `SETUP.md`, README, website and native Help destinations consistent. Verify that a linked repository feature is actually enabled before advertising it as a help or reporting path; VoiceInk++ GitHub Issues was disabled despite a readable `/issues` page. Treat app launch, provider/permissions, Codex skill discovery, Chrome extension loading, the YouTube helper/native host/login LaunchAgent, and optional mouse mappings as separate receipts. The public `scripts/install-first-use.sh` is only for a Mac without VoiceInk++ installed; it must refuse replacement and never impersonate the guarded Mini-to-MacBook native update. Only the optional YouTube helper installs a login LaunchAgent; the old fork auto-update LaunchAgent stays disabled. A successful build or `open` exit is not a persistent-PID or working-Chrome receipt. Self-improved — 2026-09-24: the shareable setup and disabled Issues setting exposed these distinct publication and installation boundaries.

Follow every public installation link and require its advertised build to agree
with the intended downloadable release. Run the published checksum command in an
independent download directory; require bare distributed filenames, not builder
paths. Keep curl integrity/signature checks separate from browser quarantine,
first-open and isolated-user onboarding proof. Self-improved — 2026-09-30: the
Mini reproduced stale setup links and a matching-but-unusable checksum manifest;
see “Check public checksum manifests as a downloaded user” in `LEARNINGS.md`.

VoiceInk++ is a commercial-free personal fork. Upstream license validation, trials, purchase/upgrade
screens, Polar or other checkout clients, affiliate promotions, trial-expiry transcript injection,
and remotely supplied promotional announcements are rejected systems, not features to restore.
Before accepting any upstream port, inspect its dependency, project-membership, onboarding,
dashboard, settings, transcription-delivery, and announcement changes for those paths. Preserve
functional errors, recorder feedback, local macOS notifications, and Sparkle update behavior; the
ban is on monetization and promotional runtime, not useful operational messaging. Keep
`CommercialFreeDistributionTests` passing and update its forbidden surface list if upstream changes
commercial symbol or file names.

For a recorder stuck on **Transcribing**, diagnose the resolved provider before touching delivery code or downgrading the app. Read the active fork domain `com.ethansk.VoiceInkPlusPlus`, decode every `modeConfigurationsV2` entry, and inspect `selectedTranscriptionModelName`, `isRealtimeTranscriptionEnabled`, and `selectedLanguage`; Mode overrides are authoritative over top-level model/language values and are frozen per recording by `ModeRuntimeResolver`. Do not inspect only the legacy `com.prakashjoshipax.VoiceInk` domain. Correlate the resolved provider with `StreamingTranscriptionService` lines such as `Streaming start requested model=` and the first server/socket error. Before switching providers, run a direct end-to-end transcription against the proposed endpoint using synthetic, non-private speech and require a successful response within the normal latency range. Preserve the installed delivery binary when provider/account evidence explains the failure.

For zero-audio recordings, empty-buffer/HTTP 400 failures, or problems after Bluetooth/default audio
route changes, read [references/audio-capture-recovery.md](references/audio-capture-recovery.md).
An output-only change can invalidate input capture without changing its ID or sample rate; require
actual PCM evidence, preserve active/paused recordings, and never reset shared hardware to test it
while OBS or another protected audio session is active without Ethan's approval.

For OpenAI transcription quality, prompt/context, keyword, language, delay, or session-reuse
work, first read [references/openai-transcription-quality.md](references/openai-transcription-quality.md).
It separates dated official model facts from VoiceInk++ choices and recognition quality from
transport success. Re-fetch current model guidance and use human-referenced, same-audio comparisons
before claiming a context or delay setting improves accuracy; never treat a full prompt budget,
local context-log count, synthetic probe, or catalog score as that evidence.
When reducing Vocabulary hints, preserve stored terms and every non-OpenAI provider; review
the OpenAI-only exclusion set rather than lowering an alphabetical keyword cap. Confirm the
per-recording realtime/fallback list is identical and the current live setting separately.

For OpenAI GPT Live Transcribe work, use `scripts/openai-transcription-probe.swift` with synthetic PCM16 mono 24 kHz plus its WAV equivalent before building, installing, or changing active Modes. Require `session.updated`, at least one real delta, a non-empty completion, and a successful `gpt-transcribe` completed-audio fallback. The WebSocket connection is `wss://api.openai.com/v1/realtime?intent=transcription`; `gpt-live-transcribe` belongs only in `audio.input.transcription.model`. Never revive either rejected `?model=gpt-live-transcribe` or `?model=gpt-realtime-*` connection form. The probe reads the VoiceInk++ key from local secure preferences and must not print transcript contents or credentials.

Keep every OpenAI realtime and completed-audio prompt within VoiceInk++'s 992-character production
cap, leaving a 32-character reserve below the provider's 1,024-character hard maximum. Keep those
values separate in source and test their relationship so a future provider-limit update cannot
silently erase the reserve. The synthetic provider probe must still exercise exactly the hard
boundary with the same prompt on both paths; a short probe prompt cannot detect a context-composition
regression that makes GPT Live reject `session.audio.input.transcription.prompt` before the first
partial. For context-bearing installed tests, require the counts-only trace to prove
`promptChars <= 992`, `Streaming connected`, and `Streaming first partial event`; a later
batch-fallback paste does not prove realtime worked.

Treat OpenAI transcription `prompt` as contextual guidance, never as a guaranteed output formatter.
The API exposes no numeral-normalization switch: a physical `gpt-live-transcribe` test ignored an
explicit number-word-to-digit example. Preserve live preferences until a documented dedicated
control is proven; deterministic numerals require a separately tested VoiceInk++ post-processor.

For optional recent context, use only exact active-Codex messages; same-Mode History is no longer
a production fallback. While verified Codex is frontmost, require the counts-only trace to show
`Codex context captured messages=` and `request context frozen ... codexMessages=` greater than
zero; do not infer exact task context from a recent session file, title, Accessibility destination,
or shared Mode. Require explicit final assistant metadata: current native rollouts use
`phase=final_answer`; accept legacy `channel=final` only when phase is absent. Exclude progress,
unknown, malformed or conflicting metadata, and verify the real producer shape before release.
Retain at most two whole-word excerpts within the independent 400-character context budget.
The normalized static prompt stays first and Vocabulary remains a separate field. Test realistic
long messages, escaped expansion, no-context fallback, and post-fit counts; a zero included count
can otherwise look healthy while ordinary dictations lose all useful context. Keep task identity,
message, transcript, prompt, and keyword text out of logs. The retired History policy lives only in
test fixtures to preserve its comments and negative evidence; never restore its runtime query.

For live Codex selected-text and screenshot context, keep one per-recording chronological
stream: bounded selected-text excerpts, saved native screenshot **paths only**, and HUD-only
speech. Capture screenshots only from the configured macOS screenshot folder while the
recording is active, require the native screenshot metadata marker, and never read pixels,
pasteboard images, or a whole selected passage into GPT Live's prompt. A path in final text
lets a local Codex agent inspect the file; it is not an uploaded image attachment and may
be inaccessible to cloud recipients or after a file moves. The preview now grows with its
content up to each display's safe height, then scrolls; keep the mini/notch host windows,
stacked cards, and notification clearance synchronized. Require
`savedScreenshotPathJoinsSpeechAndSelectionsInCaptureOrder`,
`onlyFreshNativeScreenshotsEnterLiveContext`,
`recorderContextGrowsBeforeItsScreenBound`, and the existing chronological-preview and
HUD-only guards before release. A test of final XML alone does not prove the live HUD.
Test measurement shortcuts across their boundary at each relevant width/scale; a
character count does not prove the text fills the display. Both speech and typing
must retain content-driven growth without jumping to maximum height. Self-improved —
2026-09-27: a Mini AppKit probe disproved the 3,000-character fill assumption; see
LEARNINGS.md, “A character-count shortcut can jump the HUD to full height”.
For intermittent first-highlight misses, test delayed mouse-edge dispatch using each
event's original coordinates and recipient, capture attachment before the audio
handshake, and the gesture-time speech anchor. A background source needs a stable
visible window and range geometry; do not replace that proof with multi-app polling.
Commit successfully read text before optional off-main chat labels, and verify label
updates cannot replace text/timing or reorder references. Require
`SelectionGestureWatcherTests` and `LiveSelectionFallbackTests`; keep installed
physical acceptance separate from reducer/source/fixture evidence. Self-improved —
2026-09-27: source review found collapsed delayed drags and canceled captured text;
see LEARNINGS.md, “Selection edges and committed text must survive delayed metadata”.
Selection readers must preserve each Accessibility range token's own text/bounds pairing. A stale
nonempty accessor must not mask a gesture-proven alternate accessor. Cache only
inside one bounded attempt; do not relax background geometry or add idle polling.
Self-improved — 2026-09-28: source inspection and stale-accessor fixtures exposed
cross-representation bounds and premature fallback termination.
Prefer gesture-proven ancestor text over the nearest boundless pointer fragment,
but retain that nearest fragment when the bounded walk finds no proof. For foreground
Codex, compare the pointer before returning a focused marker and preserve explicit
pointer selected text over a containing broader marker. Keep aggregate rectangle
size diagnostic-only: a hard span-size veto lost live partial-word highlights.
Background reads still require geometry. Self-improved — 2026-10-09: retained
build-414 misses, the focused-marker fast-return source gap and build-415 pointer
fixtures; see LEARNINGS.md, “Drag-span size veto lost live Codex highlights”. Do not walk
past a focused editor into unrelated aggregate text. Containment plus overlapping
bounds is not exact-selection proof. A longer marker may replace non-editable
leaf-local text only when a fresh single drag has usable endpoints, the earlier
range misses an endpoint, and the consistent marker covers both. Never widen an
editable field's selection. Preserve double/triple-click, delayed and autoscroll
uncertainty rather than inferring glyph boundaries or trimming text. AppKit global
drag click counts can be zero; correlate actual retained gesture diagnostics before
assuming one. Self-improved — 2026-10-09: single-address broadening fixtures and
the live zero-click drag trace; see LEARNINGS.md, “Overlapping ranges are not
precise highlights”. Exclude menu/tooltip-level overlays from source identity without
excluding real floating content windows or preferring a main window underneath
one; preserve the content windows' front-to-back order. Keep misses diagnosable with counts-only
marker availability, degenerate-bounds and pre-read callback-lag/drop traces; never
log selected words or substitute guessed event routing. Self-improved — 2026-10-09:
the resolver regression fixtures prove these traps and safety boundaries; require
physical rendered-symbol highlighting before claiming a KaTeX-specific fix.

Keep every separately highlighted block in capture order, including equal speech anchors
and a run with no recognized speech. Those cues form a best-effort reading trail, not a
replacement for the spoken request or proof of precise timing. Require
`repeatedHighlightsWithoutSpeechPreserveReadingTrail` and
`silentHighlightsProduceReferenceOnlyXMLInCaptureOrder` alongside the HUD and final-XML
guards. Ethan explicitly reversed the earlier latest-only rule on 2026-09-25.

For keyboard prose, Enter commits the current typed section at the speech position
observed then, without finishing capture; Shift+Enter inserts a newline and
Command+Enter keeps finish/send/steer. Blur and accepted context also commit at
their boundary, not the first keystroke. Keep the editable run outside the committed
timeline but include it in recovery snapshots; capture end commits it after all
final speech, including a provider tail not streamed live. Preserve first/latest
actual edit times, and prevent repeated or mirrored end callbacks from duplicating
the run. Require `typedRunsLandAtCommitAcrossSpeechHighlightAndCaptureEnd`,
`returnCommitsEachRunAtItsOwnSpeechAndRespectsIMEAndMirrors`,
`commandReturnFinishFlushesWithoutSealingSoCaptureEndPlacesTheRun`, and
`productionPipelineArchivesTypedRunsWhereTheyWereCommitted`.
User correction — 2026-10-10; supersedes the older Enter-newline contract.
Measure the active editor as it changes,
including its trailing insertion line; do not wait for blur to
resize the mini/notch host. Only after an explicit typing shortcut or click to type may an accepted
highlight or screenshot return focus to that session's chosen mirrored editor.
Finalization disarms this; ordinary speech updates and app switches must
not chase focus. Adding Command to the standard Shift-Control-Option start requests
initial editor focus for that exact start reservation, never another/newer session.
Forward modifier releases and preserve Primary/Next delivery ownership. Require
`RecorderTypedInputTests` plus the existing shortcut and route guards; distinguish
microphone-free editor/controller fixtures from physical shortcut/context acceptance.
User-requested keyboard focus behaviour — 2026-09-26; restored on 2026-09-28:
return focus after each accepted highlight/screenshot once typing is engaged.
Default an absent automatic-return preference to enabled, preserve an explicit
false opt-out, and permit automatic return only while the microphone is off and
not transitioning. Recheck that live policy at the queued focus boundary, not
only when capturing context: a remembered typing opt-in must not steal Codex's
caret during speech. Explicit editor clicks remain independent. User correction
— 2026-10-17; see LEARNINGS.md, “Automatic context return is typing-only, not a
lifetime opt-in”. Bind initial
focus before the audio handshake, allow keyboard input during microphone-off
startup, and preserve already-typed prose in History if startup fails.
User correction — 2026-09-28: remove the Unfocus button and its reserved gutter.
After accepted context, coalesce a short cancellable return that waits for mouse
release/editor mounting and verifies key-window plus first-responder ownership;
never drop the pending initial focus when an initial selection arrives first.
Stop after success or expiry, and cancel on finish. Do not add idle focus polling.

Keyboard-only start must remain an active composing session, not gesture-Pause:
Primary still finishes it rather than unexpectedly enabling the microphone. Both
Command keys AND both Option keys together are the additional Start/Finish
shortcut: idle starts microphone-off typing and focuses its editor; an active
recording or paused composition finishes through `primaryCurrentInput` regardless
of whether that editor currently has focus. Do not consume the first active-session
chord merely to refocus the editor. Initial focus and focus return after accepted
selection/screenshot context remain separate behaviors. Ethan reversed the
refocus-before-finish shortcut behavior on 2026-09-29; require
`typingChordFinishesWithoutRefocusingUnfocusedEditor` and the shared-monitor
finish guards.
Holding Shift while completing the four-key chord instead finishes an active
recording/paused session through the existing clipboard-only Won't paste route.
Freeze Shift in the key event, not its asynchronous action; idle Shift is a no-op.
Test all 24 key orders with and without Shift, balanced releases, shared monitor
ownership, and no extra action when Shift changes after a consumed chord.
User-requested Shift finish — 2026-09-28.
User-requested late Shift — 2026-09-30: after a normal four-key finish, a fresh
Shift-only tap (either Shift key, accepted on release) selects Won't paste for
that exact stopped session before its first irreversible output effect. Bind its
ID before the asynchronous stop; never search backward, affect a newer capture,
or undo an issued paste. Ignore Shift used to type a capital or prefix a modifier
chord, including Primary's mouse macro, and forward every Shift event. Require
`standaloneShiftTapObservesOnlyReleasedShiftWithoutSwallowingEvents`,
`typingStopSecondChanceShiftIsExactOneShotAndRejectsStaleResults` and
`lateShiftClipboardCompletionRetainsFormattedPromptAndHistory` with the existing
Primary/Next and shared-monitor guards. See LEARNINGS.md, “Late Shift belongs only
to the exact four-key-stopped result”.
User-requested timing correction — 2026-10-01: keep a separate typing-stop
choice open through formatting, archiving and the asynchronous delivery-queue
wait, with at least one second from stop for fast typed-only results. Primary's
earlier completion-policy freeze is not this cutoff. Seal/read the choice
atomically after the queue wait, before paste/Return/custom commands, or before
a Respond request starts; recheck cancellation/lineage after any grace wait.
Require `lateShiftSurvivesProviderFreezeArchiveAndDeliveryQueue`,
`typingStopGraceKeepsFastResultsSelectableAndSealsBeforeEffects` and
`lateShiftSuppressesRespondAndCustomCommandOutput` with the existing guards.
For styled History retention, assert readable words through the production
`HistoryContextPresentation` plain-text projection and independently assert exact
canonical archive bytes and metadata. Raw producer-LaTeX can split words;
substring failure alone does not prove text was lost. Self-improved — 2026-09-30:
the first late-Shift release gate exposed this assertion trap; the corrected
523-test gate passed. See the same late-Shift entry in `LEARNINGS.md`.

History's **Copy** returns raw authored speech/typing; **Copy with flow markers**
returns the entire readable XML/context, not the retired LaTeX producer bytes.
Decode only the known presentation grammar, preserve malformed/unknown text,
and never rewrite stored History or truncate either copy. Derive the main message
and structured copy from one shared projection: prefer final Flow content, then
the retained live timeline or the existing recovered-context wrapper. Show Flow
content without expanding the row; expansion may expose authored-only raw text,
not a second exit-draft/recovered message. Preserve provider-final words separately
when a live snapshot is earlier; never invent missing timing or overwrite either
source to reconcile the UI. Exercise real shared buttons in cards, compact lists
and original/enhanced detail headers, including raw-only and recovered records.
User correction — 2026-10-17; see LEARNINGS.md, “History's Flow timeline is the
main message, not a second exit draft”. For Codex paste, keep the editable opening
and full-file preview plain; complete inline context uses fixed colours for
selection/screenshot metadata and rainbow only for authored speech/typing inside
its later blocks. Use the shared response palette once per message and continue
across blocks/lines; never colour the editable top paragraph. Compact generated
tag scaffolding only, preserving payload paragraphs and indentation. This latest
inline-rainbow clarification supersedes the earlier no-rainbow inline rule.
Count the actual coloured UTF-16 expansion against
the existing attachment threshold, and reject an oversized plain candidate before
colouring it. Archives remain canonical plain XML. User correction — 2026-10-17;
supersedes the earlier byte-for-byte formatted-copy contract.
Do not classify the four-key chord as Primary multi-click, resume the mic, or
reinterpret a repeated chord as a pending-result action. Forward all modifier
releases. Ethan corrected start-only behaviour
on 2026-09-27, then added both Option keys to avoid his existing both-Command shortcut.
Require all four physical-side flags; aggregate Command+Option is not enough.
Leave both Command alone and every partial/released chord untouched.
Recognize reserved typing chords only in the shared monitor with their owner
callback. Replay CGEvents through recording, visible-panel and Mode monitors in
head-insert order, not just directly through the action handler. Self-improved —
2026-09-27: a newer non-owner panel monitor swallowed Finish; see LEARNINGS.md,
“Shared shortcut monitors must not consume unowned chords”.
Do not prepare a streaming provider or submit the empty recovery WAV until capture
was explicitly enabled. Test the actual pipeline with an audio-session spy and a
delivery sink: authored text completes and is delivered once, empty input delivers
nothing, and neither calls transcription. Group speech/typed timing in XML only
where context is allowed; recognition-activity times are approximate, not VAD.
Test a final transcript longer than its last partial: every authored word must stay
in a speech group without invented timestamps. For readable queue previews, exclude
selected quotes from the raw opening and keep the duplicate-preview interpretation
in both installed and public skills; plain-app output is unchanged.
User-requested microphone-off typing and timing — 2026-09-27.

For authored rainbow presentation, test the exact shared palette, nonblocking
counter protocol, inert escaping, and the content-first expansion budget. Only the
opening uses a rainbow; XML uses fixed silver speech/typing, cyan selection and
magenta screenshot sections, as Ethan clarified on 2026-09-27. Generate colours only at final styled AI output, never through a provider
request or on live partials. Preserve all words on a plain fallback and validate the
complete production message, not isolated formulas: raw XML blocks can suppress
inline math. Current output omits the outer context envelope; keep the paragraph
boundary after the readable preview and every inner tag, timestamp and source
attribute. Older raw context envelopes still require a following blank line;
the installed host's lexer reproduced that missing-boundary bug.
Rendered bubbles do not prove queued rows
render math. Keep installed/public interpretation guides aligned, including historical
colour decoding. See LEARNINGS.md, “Whole-message XML envelopes can suppress math rendering”.

For the full-prompt viewer, continue the fixed per-word palette across wrapped
and explicit lines, speech/typed sections, and later messages in the same proven
chat. Never restart the gradient on every line or section. Context consumes no
rainbow positions. Reserve the next start after the last authored word once per
durable archive, keep it in the saved viewer, and never advance it on reopen.
Keep viewer cursors separate from the assistant quote counter and plain editable
Codex previews. Use only passive app-owned chat identity; ambiguous panes use an
unscoped fallback, never AX focus or a guessed delivery destination. Verify word
colours and whitespace, not a horizontal CSS gradient that resets by x-position.
User-requested continuous viewer rainbow — 2026-09-30; Mini tests and browser
rendering are recorded in LEARNINGS.md.

For compact italic metadata, retain one blank-line gap between different section
types/colours and compact only consecutive matching types. Keep literal quotes and
apostrophes in XML character data while escaping them in attributes; preserve
ampersand/angle escaping and exact text round trips. Test valid thread identities
when asserting task-title attributes. User-requested section spacing and readable
apostrophes — 2026-09-27; see LEARNINGS.md, “Compact metadata needs a boundary between section types”.

For default compact file-linked prompts, persist the complete canonical message before
publishing its link, with a private directory and exclusive, synced, owner-only
files. Never auto-expire them or replace full History/Copy recovery with a preview.
For short local-Codex context messages, preserve the same plain editable opening
and interleaved angular markers first, then append the exact cached canonical
timeline underneath only when the whole paste is below 5,000 UTF-16 units. Count
the encoded link, editable opening, paragraph separator and timeline together;
authored words appear in both. Never replace the opening with XML or prepend a
read-skill reminder. Do not embed the skill or reread the newly written archive.
At 5,000 or more, retain the compact opening and its full-prompt footer. Agent
interpretation guidance already available in a chat can be reused; it does not
require rereading the skill every message. User correction — 2026-10-08.
User-requested inline short prompts — 2026-10-08; see `AgentFlowPromptArchiveTests`
and LEARNINGS.md, “A paste-event limit is not a same-draft attachment limit”. Ethan restored that
link because queued messages hide the footer; never remove it as duplication.
Only compact previews with hidden context include the
separate `Read the full prompt before answering.` footer; pure speech/typing is
already complete inline and omits the mandatory read. Retain the optional opening
link either way. Decide from structural section tags, not authored mentions of
captures; preserve possible TTS-overlap metadata and fail closed for unknown
context types. When needed, the footer points to the same viewer with a literal
`full prompt` label and no math commands. Preserve manual-paste parity.
User-requested conditional footer — 2026-10-07; link restoration and inline angular markers
— 2026-09-29/30; supersedes the 2026-09-28 opening-link removal.
The optional offline HTML companion parses canonical XML into coloured sections;
metadata stays in disclosures, but there is no second embedded Full source copy.
The human-facing link uses that
viewer, which must expose the exact plain archive through early `agent-flow-source`
metadata and a visible source link. Embed only bounded decoded local raster
screenshots, never remote URLs, SVG/HTML, pipes, devices or symlink targets; retain
original paths and show an explicit fallback when a preview cannot be produced.
Keep image data out of the canonical prompt and limit viewer resource usage.
Keep file-link labels literal until a supported mechanism has actual disposable
bubble evidence. Both normal delimiters and parser-valid dollar math displayed
raw commands in the real recipient; a tokenizer or standalone KaTeX pass is not
link-renderer acceptance. Preserve decoded target identity. Self-improved —
2026-09-30: Ethan's screenshot rejected the parser-valid build-393 rainbow link;
see the matching rejected approach and learning.
Escape all displayed payloads,
disable DTD/entity resolution, retain malformed/unknown text, and never silently
truncate the canonical captured selection to meet a preview or viewer budget.
App-specific transport limits are separate and must remain documented.
Keep every authored word inline; never truncate it to fit a host attachment
threshold. Only context payloads/metadata move exclusively to the archive; retain
event markers and the single footer. Large pastes may still become host attachments.
User correction — 2026-09-29. This is content formatting, not another delivery
route: Primary still posts one generic paste; raw/skip and exact Next paths retain
their contracts. Test archive failures/permissions, full metadata preservation,
compact formatting and Primary/Next/queue/HUD guards. A cloud recipient cannot
read an arbitrary Mac path. User-requested replacement — 2026-09-28.
Test the native file-reference scanner/resolver as well as the Markdown href,
then check the viewer and its canonical source and compare archived bytes. Use encoded
absolute paths without angle delimiters. Self-improved — 2026-09-28: build 374's
native scanner retained `<`/`>` and opened a nonexistent IDE buffer despite a
correct Marked href; see LEARNINGS.md, “A rendered file link is not proof”.
The earlier attachment-plus-opening exception is superseded after intermittent
live preparation/opening failures. Its historical evidence remains in LEARNINGS
and FAILED_APPROACHES; do not restore AX receipts or two-paste choreography merely
because one attempt appears to work.

For Won't paste in paste mode, prepare the same preview using the already-resolved
Mode's styling and the complete saved archive, without consulting the foreground
app: there is no manual-paste recipient yet. Keep the action strictly
clipboard-only: no AX target mutation, paste, Return, output command or
future-Cmd-V watcher. An already-selected result resolves no target/lease;
a late selection during the queue wait releases the acquired lease and uses
the identical clipboard formatter without invoking delivery. Raw/skip remains
verbatim; automatic paste filters ordinary recipients before applying the native
agent/known-remote presentation rules.
On archive/preview failure, copy the complete canonical text.
Compare normal and clipboard-only production-pipeline outputs, allowing only each
session's unique file path and rainbow offset to differ; use an isolated pasteboard
and prove History/archive retain all words and timestamps. Include recorder, source
app and unknown foreground identities, not just a Codex fixture. Update the old
plain-only style guard, not just formatter tests. Self-improved — 2026-09-28:
the clipboard branch bypassed compact formatting; see LEARNINGS.md, “Clipboard-only
completion must share local-Codex presentation without delivering”.
Self-improved — 2026-09-29: the recipient guard reproduced the remaining plain
clipboard failure; see LEARNINGS.md, “Won't paste has no recipient yet”.

Never infer selection source from a global monitor's reconstructed CGEvent target
PID: it can name the recorder itself. Sample the frontmost PID and pointer inside
the monitor callback, structurally exclude self, and keep capture text-free while
idle. Retry only after a real gesture and retain source-window/cancellation guards.
Self-improved — 2026-09-27: live build-358–360 logs proved self-targeted reads; see
LEARNINGS.md, “Global monitor CGEvent recipients are not selection sources”.

Keep the exact `RecorderStateProvider.updateTypedInput(_:)` witness when adding
timestamp overloads; test edits through the protocol used by the real HUD, not only
the concrete session. A defaulted extra argument is not the same Swift witness.
Self-improved — 2026-09-27: the release gate caught typing falling into the protocol
compatibility no-op; see LEARNINGS.md, keyboard-only completion.

Verify scaled recorder controls with actual window-targeted mouse events at minimum,
default and full scale, not only frame math or AXPress. Keep the AppKit host at its
physical size and scale the content within SwiftUI; an ancestor NSView bounds
transform drew the buttons correctly but misrouted clicks. Preserve nonactivation
and explicit editor-only keyboard ownership. Self-improved — 2026-09-27: the native
fixture failed at 0.5/0.85 and passed after this correction; see the scaled-HUD lesson.
Keep a separate nonactivating background drag surface instead of restoring host-wide
mouse-down movement, which can steal control clicks. Cover drag events and controls
at minimum, default and full scale, and preserve user-positioned panels on resize.

For a requested Soniox-versus-AssemblyAI comparison using saved recordings, read
[references/provider-realtime-ab-test.md](references/provider-realtime-ab-test.md)
and use `scripts/compare-realtime-stt.mjs`. Dry-run the corpus first, require one
successful candidate-provider probe before the full run, keep private reports in
`/private/tmp` with mode `0600`, and adjudicate meaningful transcript disagreements
against the source audio rather than treating text fluency as ground truth.

For a realtime stop that pastes nothing or appears to skip Return, separate transcription finalization from delivery before touching Primary or Next routing. Correlate `Streaming stop completed ... finalChars=` with `pipeline: about to DELIVER finalChars=` and the selected Mode. `finalChars=0` is not a successful final: the completed audio must take the existing batch fallback before any delivery route runs. A non-empty Primary trace with `targetAutoSend=none` instead means the current input app's Mode intentionally disabled Return; do not reinterpret it as latch contamination.

## Normalize the two mouse controls before reasoning

- **Primary button** is the preferred name for Ethan's normal recording control. **Normal button**, **thumb button**, **toggle button**, **recording button**, **same button**, and historical **G5** are aliases. First press starts. While recording, one press performs a base VoiceInk normal stop after the shorter of the macOS double-click interval and 0.45 seconds into whichever system keyboard input is focused at final delivery (`primaryCurrentInput`). Two presses cancel that pending stop and, if no third press arrives through the full macOS multi-click interval, finish the session to a recoverable local audio/HUD draft plus final clipboard text without paste, auto-send, Mode command/response, or playback mutation. A third press inside that interval cancels the clipboard finish and pauses capture; a fourth press inside one more full-system continuation finalizes normal Primary paste with only that session's configured auto-send suppressed. Ignore a fifth press inside the consumed gesture. While paused, one fresh press resumes after the short second-press decision window; two fresh presses inside it propose the same clipboard-only/no-paste route, but a third inside the full continuation clears it and resumes the same capture. Primary owns no exact input or destination Mode.
- **Next button** is the preferred name for the separate forward/secondary control. **Forward button**, macOS **Next Track**, **Next Track media key/action/event**, **secondary mouse button**, **latch button**, and **retarget button** are aliases.
- Unqualified **toggle** means the primary button's start/stop lifecycle and corresponding shortcut mode. Never reinterpret it as a Next-button destination toggle. Commit `671b4c7` tried that and was deliberately reverted by `bed22b7`.
- **Second chance** names only the post-primary-stop, still-transcribing retarget route. **Latch** means preserve/replace one session's destination; it never means toggle the destination off.
- If Ethan says “input on start of transcription” while contrasting the two buttons, use the corrected meaning **recording-start input**. Recording precedes transcription.
- Ethan's verified G502 X LIGHTSPEED `Desktop: Default` mapping uses the upper side thumb control's `speech to text` Shift-Control-Option macro for the primary button and a different control explicitly labeled `Next Track` for the Next button. G HUB's `Mouse Button 4` and `Mouse Button 5` are separate controls; never infer that the spoken alias “forward button” means raw Mouse Button 5.
- When wording remains ambiguous, restate the physical control, timing, and destination value before changing behavior. Never invent a route from an alias.

For a G HUB sanity check, confirm the live active profile, onboard/software mode, resolved assignment diagram, and VoiceInk++'s stored shortcut. Raw profile card IDs or historical G-numbers alone are insufficient to identify the physical control.

For source-tagged mouse input, preserve Ethan's start-only edge contract: fully idle Start runs
on down, its matching up is consumed even across async startup, and every non-idle gesture stays
on release. Do not replace this with a down-triggered chord for every action. Karabiner's documented
`send_user_command` may target VoiceInk's own strict, bounded UNIX datagram receiver; never reuse
Agentic Mouse's endpoint or emit the old chord as a fallback. Keep independent source cycles,
serial ingress timestamps, receiver/session generations, and positive ordinary-input readiness
after launch/wake. Commands cannot unlock the gate; gate changes invalidate queued edges and
uncommitted starts without canceling an established recording or independent keyboard gesture.
Require native phase/slow-start/order/session tests plus attended physical source down/hold/up,
Start-release-no-op, later release gestures, context-menu, Next, and lock-screen checks before
physical acceptance. Preserve retired controls and the mouse owner's exact-device lease rules.

For receiver startup or release readiness, read
[Primary socket qualification](references/primary-input-socket.md). A private socket file is
not proof of a bound receiver; require a passive datagram connect after installation, without
sending a recording command. Self-improved — 2026-10-15: a restored socket's device-only
marker mismatch left build 428 unbound despite its correct file permissions; see the matching
startup-recovery entry in `LEARNINGS.md`.

When several hardware controls converge through Karabiner as one modifier-only Primary chord,
establish the ownership boundary before trying to identify the source. An exclusive HID-open failure
such as `0xe00002c5` means VoiceInk++ cannot recover F19/F21/F22 identity after Karabiner has collapsed
it. Use event-tap-sampled monotonic time at the final VoiceInk++ handler instead: suppress only the
second complete chord in a mechanically near-simultaneous burst, anchor the window on the last
accepted chord rather than the rejected duplicate, and reset it across Next and monitor-reset
boundaries. Keep that window far below the existing Primary double/triple/quadruple gesture intervals; never
restore the legacy 500 ms cooldown. Require reducer and handler tests proving the duplicate cannot
cancel `.starting` or become a clipboard-only finish, plus physical single-control, paired-release, double-click,
triple-click, quadruple-click, fifth-click, and lock-screen checks.

For modifier-only Primary regressions, inspect the complete `flagsChanged` sequence. VoiceInk++ owns and suppresses only the event that completes the configured Shift-Control-Option chord plus any full-chord repeats; partial modifiers and every release must remain downstream-balanced. Require the pure reducer test and a physical check with a context menu already open. Never swallow the entire modifier sequence to hide a menu-dismissal symptom, because that can leave the foreground app with stuck logical modifiers.

User-requested — 2026-10-17: recording-start saved-input capture is unused/off.
Respect `FocusLockService.recordingStartInputCaptureEnabled = false` at partial-chord
staging, Start reservation and the post-audio retry; do not revive any of them from
the historical guidance below. Recording-time Next is a consumed no-op before
canceling Primary gesture decisions, while explicit post-stop second chance stays
available. Keep the three `unusedRecordingStart...` / `disabledRecordingTimeNext...`
regressions passing. Revisit recording-start capture only at Ethan's explicit request.
See the current override in `RECORDING_DESTINATIONS.md` and its qualification in
`LEARNINGS.md`; the older recording-start contract is dormant, not deleted.

For explicitly re-enabled recording-start exact-input capture, remember that Ethan's G HUB Primary macro completes its
modifiers sequentially. Electron may expose the exact composer during an earlier forwarded partial
modifier and only an ancestor container on the completed chord. Preserve one passive, short-lived
pre-chord snapshot, but recover it only when the completed-chord container has the same process and
the exact editor remains a replay-safe descendant whose identity re-resolves immediately. Never
focus or activate the app, suppress partial modifiers/releases, reuse a stale snapshot on its own,
or let this tentative Next-only capture enter Primary delivery. Keep
`primaryModifierChordExposesOnlyForwardedPartialProgressForCapture` passing and require a physical
`recordingStart` Next trace before accepting the installed release.

Keep these three routes distinct:

| Action | Destination |
| --- | --- |
| Primary button once while recording | After the double-click decision window, base VoiceInk normal stop into the system keyboard input focused at final delivery (`primaryCurrentInput`); never capture, reuse, or fall back to `recordingStart` |
| Primary button twice while recording | If no third press arrives through the full macOS multi-click interval, persist original WAV plus last realtime HUD text in History, then finish/transcribe the same session to the clipboard only; never paste, auto-send, run a Mode command/response, cancel/discard, or alter playback |
| Primary button three times in one continuous gesture | Pause capture inside the same session; no finalization or destination decision |
| Primary button four times in one continuous recording-time gesture | Finish the same paused session through normal `primaryCurrentInput` paste, restore owned playback, and suppress only this session's configured auto-send |
| Primary button once while paused | Resume capture after the short second-press decision window |
| Primary button twice while paused | Select Won't paste, then finish through the same clipboard-only/no-paste route only if no third press arrives through the full continuation |
| Primary button three times while paused | Clear provisional Won't paste and resume the same capture without finalizing or pasting |
| Next button while recording | Input captured at recording start (`recordingStart`) |
| Primary normal stop, then Next button while the newest result is still transcribing and before post-processing | Second chance: replace that newest pending session's input and complete Mode atomically (`focusedDuringTranscription`) |

Consecutive normal Primary delivery jobs form one FIFO paste cohort when a later recording starts
before the earlier job has delivered. Drain every successful transcript in order, suppress Return on
each earlier member, and let only the newest eligible queued Primary tail use its current Mode's
auto-send. An older normal Primary result may paste while the newer recording owns the microphone;
the live capture owner remains visible at the last Return boundary and suppresses that older Return.
Next/retarget, clipboard-only, cancellation, raw/skip, command/response, assistant, and non-paste
routes remain exclusive with capture and break the cohort. If a predecessor or expected tail fails,
warn and fail closed; never issue a delayed compensating Return because Primary owns no exact
destination to submit safely. The synchronous start reservation counts as continuation intent even
when an older delivery lease was acquired first: if Ethan has pressed Start again before Return-down,
suppress that older Return while the new microphone handshake waits.

Pause is capture state, not a fourth delivery route. The third Primary press cancels the pending
double-click clipboard finish and pauses. While paused, one Primary press resumes after the short
second-press window; two presses inside it select clipboard-only, and a third inside the full
continuation cancels that provisional choice and resumes. Pause/resume must not paste, change Mode, or change the tentative recording-start
target. Gate callbacks before stopping AUHAL so paused audio enters neither WAV nor realtime
streaming, keep the mirrored HUD visible with its frozen partial and pause indicator, leave media
playback and the YouTube helper untouched on both pause and resume, and let Ethan control playback
himself during that interval. VoiceInk++ may lift and restore its optional system-output mute across
pause/resume; only recording start and final stop/cancel own the media/YouTube-helper lifecycle.
Next while paused still stops through `recordingStart`.

The third press also arms one full-system continuation for click four. That fourth press is a
completion policy on the same session, not another destination: preserve normal processing and
Primary current-input paste, force only its auto-send key to `.none`, restore owned playback once,
and consume a fifth press. Store the override on the recording session and freeze it with
clipboard-only intent after the provider returns, before Mode effects. For a pending transcription,
bind all four clicks to the click-one session and hold that same bounded freeze; with no eligible
pending result, start on the first idle press immediately after reservation, without a click-decision
timer or idle quadruple. Keep the sub-90 ms duplicate coalescer and asynchronous reservation guards;
neither may delay the first accepted press. Only a real pending transcription retains the short
new-recording versus Won't paste decision, with reservation work counted inside its original deadline.

Treat a recording-time double/triple/quadruple-click as one platform-bounded sequence. Keep first-to-second capped so a
normal stop stays responsive, but after click two has canceled that deferred stop, honor the full
system multi-click interval for click three. If click three arrives, cancel the pending clipboard finish and pause capture, then keep one full-system interval for click four. If click four arrives, finalize normal paste with per-session auto-send suppression and consume a fifth press. If click three does not arrive, finalize once
with a per-session clipboard-only completion policy. Before asynchronous finalization is enqueued,
save a History record that references the finalized WAV and stores the last realtime HUD text. Mark
double-click clipboard finishes and explicit no-delivery exits as recovery-pinned so automatic audio and zero-retention
cleanup cannot remove them; only confirmed History deletion is permanent. A later double-click after
the platform interval is a fresh gesture and must never inherit the earlier double as click three.
Balance the recording and bridge lifecycle without play/pause, and clear playback ownership
synchronously before any cancellable delayed restoration task. Explicit cancellation while
transcription/finalization is in flight is separate: forbid delivery, retain the strongest available
provider result or saved HUD partial in clipboard plus history with a distinct status, and leave truly
empty cancellation distinct. An active-capture exit also finalizes and retains its WAV plus HUD draft.
Whenever a new VoiceInk recording-lifecycle edge adds a helper bridge command, validate every relay
layer rather than only the sender and Chrome extension: the menu app mapping, native host's explicit
app-to-Chrome forwarding whitelist, extension dispatch, and final state mutation must all agree.
Require a reloaded live extension/native host and one correlated cross-process log before acceptance.

Keep voice-assistant listening suppression disabled. The ChatGPT Voice experiment never proved a
non-activating mute API: `AXPress` did not change the control and pointer automation stole Ethan's
mouse. Recording lifecycle notifications remain scoped to the proven YouTube pause/resume bridge;
do not attach a mute consumer, poll ChatGPT Accessibility, move/click the pointer, or globally mute
macOS input. Reconsider only when the assistant exposes a documented background API and Ethan
explicitly asks to revisit it.

For the separately existing, user-configured microphone shortcut coordinator, unreadable is not
proof of listening and Core Audio activity is not mute state. However, a refusal-only repair can
skip every background mute: Ethan withdrew build 413 after reporting that it no longer muted at
all and explicitly requested the exact build-412 rollback. Do not reapply that policy automatically
or claim its unit tests prove live suppression. Preserve the requested rollback while clearly
retaining the older manually-muted inversion limitation. Require a supported authoritative
same-session state/control feed and physical initially-listening/manual-mute acceptance before
claiming reconciliation or extending to speaker output. This does not authorize AXPress, pointer
actions, polling, notification consumers, global input mute or private app patching.
User correction — 2026-10-09; evidence: LEARNINGS.md, “State-unreadable mute refusal was not usable
in the live Voice workflow”, and the refusal-only withdrawal in FAILED_APPROACHES.md.

Do not play Codex speech while Agent Flow records voice. Microphone-off typing may play speech; starting or resuming the microphone revokes the admitted child before hardware capture. Still send the notification and skip blocked speech without waiting or replaying it later. Keep microphone capture, manual Pause and every authored word unchanged. Stop creating live “Potential ignore” tags; retain older archives and their reader. Read `references/codex-spoken-reminder-capture.md` before changing the version-3 idle admission. User-requested — 2026-10-09; supersedes live overlap annotation. Typing-only exception requested — 2026-10-10.

Keep real-time provider partials inside the black recorder HUD. The streaming callback may update only
the active session's `partialTranscript`; it must never create or maintain provisional text ranges in
another app. Stop finalizes once and the existing Primary or Next route performs one final delivery.
Before any real-time transcription change, search `FAILED_APPROACHES.md` for the superseded
`RealtimeInputDraftSession` experiment and preserve
`realtimeStreamingRemainsRecorderHUDOnlyUntilFinalDelivery`.

Inspect the actual source guard before using the historical preference
`VIPPExactInputDeliveryEnabled`: current 435/436 source has no runtime reader for
that key, so writing it does not change delivery. The current recording-start
off-switch is documented above and does not disable post-stop second chance.
Self-improved — 2026-10-17: a source-wide reader check rejected the stale flag
advice; see the retired original-input capture entry in `LEARNINGS.md`.
On an older audited version that still reads the historical flag, false selects
base VoiceInk compatibility delivery: Primary
follows the current Mode and keyboard-focused input, no exact input is captured at start
or stop, and Next Track performs no destination action. Keep the recorder's second
destination slot visible as a warning in this state; returning a stale target would lie
about ownership, while hiding the slot would conceal that the Next/exact route is
unavailable. The flag is an escape hatch around delivery, not a fourth route, and must
never delete or merge the exact three-route contract.

Treat the visible recorder/transcription bar as the strict ownership boundary for the
Next button. While any mirrored black bar is visible, consume the complete Next Track
press even when no session remains eligible, the newest session already latched,
delivery crossed its cutoff, or exact delivery is disabled. Eligible states still
perform the routes above; an ineligible visible-bar press is a no-op that preserves the
existing destination. Pass Next Track through to media only after the bar is hidden, so
an attempted VoiceInk++ latch can never become an unrelated Next Song action because of
an internal timing race.

Preserve the recorder's action feedback mapping on every mirrored panel: a primary normal stop pulses the left/current-focus app icon; Next while recording and a successful second-chance Next latch pulse the right/locked-destination icon. Failed retargets and pass-through media presses do not pulse. Keep the Reduce Motion variant non-scaling.

Keep visible warning/error bars above the bottom-anchored mini recorder's actual rendered envelope.
The compact control bar, expanded real-time transcript, assistant panel, and stacked transcription
cards must share layout metrics with notification placement; never reintroduce a fixed compact-height
offset that overlaps a taller recorder state.

Treat transient action feedback and persistent destination ownership as separate UI state. After any stop route freezes a real exact input, keep only the stable right/locked-destination icon outlined through transcription and delivery (including compact background chips) until success, visible failure, or cancellation. Do not outline a recording-time preview, missing target, or app-only no-caret fallback until exact-composer promotion succeeds. Never persistently outline the live left/current-focus icon; it may change after the route decision and cannot represent session ownership.

For delivery, never use process-targeted Command-V or generic process-targeted Return and never activate a saved target that is currently backgrounded. Exact background text may use bounded Unicode only inside the exact-input session that resolves the saved window/editor (or meets Telegram's allowlisted retained-internal-focus fallback with independently matching chat identity), prepares one activation-state session when needed, verifies exact insertion, and proves from immediate pre/post Accessibility focus that the target did not take control. For long text, run the expensive context resolver before, at bounded periodic checkpoints, and after typing; use only a fast exact PID/window/editor/focus boundary per chunk. Codex/ChatGPT, Chrome/Chromium, and Notion may reuse renderer wrappers: empty context requires a revalidated semantic task/document scope; a stable or UUID-shaped editor/window identifier alone never proves the selected task. Telegram requires either readable matching AX chat anchors or, only for an exact audited app/version/build/layout with Screen Recording permission, a stable capture-time SHA-256 digest of the selected-chat avatar plus primary-title row that re-matches immediately before each irreversible boundary. Exclude its independently changing lower status/activity row; the complete-header digest is rejected evidence. The visual path stores and logs no screenshot, OCR, title, message, or crop bytes; any missing permission, blank/protected capture, tuple/layout drift, or stable-digest mismatch fails closed. Auto-send must use a semantic AX action, an ordinary HID key only while the exact target owns system keyboard focus, or a host-native exact-session API such as Terminal/iTerm scripting. The only accepted background Return exception is pinned Telegram 12.9/282526 after fresh exact-chat revalidation: one HID-system modifier-boundary plus Return down/up and live modifier restoration posted to Telegram's PID, followed by composer-clear verification. It is Telegram-only, one-shot, and never a generic fallback. Use the same non-activating route when the target app is frontmost but Ethan is working in a different input in that app; that case permits verified `AXSelectedText` and a proven semantic action only, never an internal-focus rewrite or generic whole-`AXValue` replacement. Rich/contenteditable surfaces such as Notion fail closed when selected-text insertion is unavailable. Ethan may switch between other apps while delivery runs; do not require his starting foreground PID to stay frozen. At recording start only, an already-active app/window/task with no caret may passively identify one proven main composer for a later Next route; it must never set `AXFocused`, move the caret, or disturb a secondary field that Primary should continue to use.

Verify auto-send by route and surface. Primary `primaryCurrentInput` already owns the system keyboard focus: after the fixed paste-settlement interval, issue exactly one ordinary HID Return down/up directly, with no System Events, app classifier, Accessibility traversal, exact-input resolver, verification, or retry. Killing a timed-out `osascript` helper cannot cancel an Apple Event already executing server-side in the shared System Events daemon, so a bounded helper is not a Primary isolation boundary. Exact Next routes remain surface-specific. A chat composer must clear/reset; a newline or other non-empty mutation is `modifiedWithoutSubmit` and must not be retried. Any exact foreground route that still uses System Events must run it off MainActor through `BoundedAppleScriptRunner`, enforce the one-second deadline, kill the helper at expiry, and never retry an indeterminate Return. Terminal/iTerm must capture a stable window-ID plus TTY/session-ID pair and bind text plus Return to that same pair in one host-native operation—never PID/AX text followed by a native newline. Bind the asynchronous identity lookup to the decision moment with the selected-tab AX control and a readable AX/native content fingerprint whenever sibling tabs/panes exist; wrapper/window equality alone is insufficient. Apple Terminal paste-only fails closed because it has no proven exact-session no-Return API; iTerm may use native `newline false`. Verify native contents before/after for the inserted text and prompt-tail transition; mutable titles are not identities and scrollback/full-screen rewrites are indeterminate and never retried. Run host scripting off MainActor with a hard timeout and kill the helper at expiry. Send AppleScript source through stdin and return captured terminal buffers through bounded length-framed stdout; never expose transcripts or scrollback in argv, environment values, or an interpolated shell command. Generic editors can verify an exact readable change but cannot use it to justify a retry. Only a readable unchanged OpenAI composer that still owns exact system keyboard focus may receive one normal-HID Return retry. Restrict semantic Send to proven chat bundles and the nearest shared composer container, and normally require an explicit Send label. Never infer Send from an arbitrary unlabelled OpenAI square because the same slot can be Stop; the sole exception is an exact audited ChatGPT app/version/build/Chromium tuple whose unique idle button is revalidated as still unlabelled, enabled, same-window, and pressable at the irreversible boundary. Treat unreadable post-state as indeterminate telemetry rather than a proven success or a visible false-failure error. Rendered-message echo remains optional telemetry. Never treat AX/event acceptance alone as success.

Keep Ethan's required compatibility set explicit: Codex desktop, ChatGPT's Option-Space floating window, Claude Code in its Terminal/iTerm/Ghostty/editor host, Telegram, Google Chrome, and a selected card/editor in Notion (`notion.id`). Use disposable inputs and the scenarios in `BACKGROUND_DELIVERY_TEST_MATRIX.md`; for Notion, create/use a disposable card or page and never mutate Ethan's current to-do board. Mark unavailable surfaces **not tested** instead of extrapolating from another app. Telegram can reuse an editor wrapper across chats and may hide its AX tree while backgrounded; retain its captured editor only when the exact structure and Telegram-internal window/editor focus still match plus either readable AX chat anchors or the exact audited avatar/title-region digest revalidates. Empty AX context without that visual proof, hidden/mismatched anchors, an unavailable capture permission, or a changed stable-region digest fails closed.

For live compatibility work or an intermittent rapid-recording report, use `scripts/live-delivery-trace.sh start|status|show|stop` instead of rebuilding an ad-hoc unified-log pipeline. It writes daily mode-0600 traces under `~/Library/Logs/VoiceInkPlusPlus/DeliveryTrace`, removes files older than seven days, and keeps only allowlisted recording/job/audio lineage, provider timing/counts, transcript length/digest, destination/delivery metadata, exact-input identity state, and foreground paste/Return outcomes. Transcript text, prompts, provider error bodies, screenshots, and chat titles must never enter the trace; transcription failures retain lineage but redact the error body. Read [references/telegram-live-test.md](references/telegram-live-test.md) before touching Telegram's UI or interpreting its identity trace. The detached runner must remain launchd-owned: a plain background or `nohup` child is reaped when Codex's bounded command shell exits and can silently leave the physical test untraced.

Treat a UI-automation denial as a safety boundary, not an invitation to recreate the blocked tool with ad-hoc Accessibility mutations against Ethan's live app. In particular, never repeatedly post ChatGPT/Codex private activation-state events merely to inspect its background AX tree: this can destabilize keyboard focus and restart the app. Prefer existing VoiceInk++ traces, offline bundle inspection, or a disposable app/task. Distinguish `/Applications/ChatGPT.app` from `/Applications/Codex.app` by saved bundle URL/executable because both may report `com.openai.codex`. A unit test, AX success code, or mocked Send button never proves ChatGPT submission; require the actual intended app surface to clear/reset without focus theft, and compare recorder start/stop latency with the accepted baseline before release.

Never launch VoiceInk++ with `open -j`: that globally hides every recorder panel even when its
WindowServer geometry is correct. Use `open -g` for a background launch, then verify the process is
inactive but not hidden before asking for a physical Primary test.

Do not interrupt what Ethan is doing now: if an authorized update is waiting for
his recording, typing or pending transcription, wait automatically rather than
asking him to stop or confirm that he is using it. Preserve the live session,
recheck quietly, and resume the safe installation when it clears; keep the required
five-second restart warning and cooperative quit veto. User correction — 2026-10-08.

Never use bare `launchctl submit` for a one-shot GUI relaunch. Launchd can infer `KeepAlive`, so an
interrupted cleanup turns `sleep; open -a <app>` into an endless focus-stealing loop. Prefer one
bounded awaited delay plus one launch. If detachment is unavoidable, require explicit cleanup and
prove the exact label absent afterward; preflight ChatGPT restart work for stale
`com.ethansk.chatgpt-relaunch*` labels.

For recorder lag or fan/load reports, sample VoiceInk++ and the wider process tree before assigning
causality. Group zombies by PPID and identify every high-CPU helper by PID, PPID, elapsed time,
command, cwd, and session ID. A `cua_node` child can outlive a one-off Computer Use inspection; map
its session ID back to the exact Codex rollout and confirm that task owns it before termination.
Never kill an unattributed Computer Use kernel or restart ChatGPT merely to remove one unrelated
zombie, because either may destroy another active task or Ethan's current conversation.

For public README or GitHub Pages changes that describe the three routes, search every visible and executable copy source—not only `README.md` and `docs/index.html`. Keep the canonical route explanations in semantic HTML and let JavaScript select existing panels rather than reconstructing contract text from a second data object; otherwise Primary/Next semantics can drift and the two Next routes disappear when JavaScript is unavailable. Before publishing, run the static-site validator, an HTML5 validator, JavaScript syntax and Markdown-link checks, a local HTTP smoke test, and credential-pattern checks. After Pages reports built, compare live HTML/CSS/JavaScript hashes with the committed files and verify the custom 404.

Do not treat Codex Computer Use's visible agent cursor as proof that macOS offers a second independent mouse or keyboard-focus channel. The installed helper's `VirtualCursor` is presentation and targeting state. `SyntheticAppFocusEnforcer` and `SystemFocusStealPreventer` are OpenAI implementation types, not documented Apple APIs or reusable system classes: public Apple primitives beneath the pattern include AX focus/main setters, AX actions, and `CGEventPostToPid`, while CPS focus-state notifications are undocumented. The native helper combines those mechanisms with refetchable AX trees and PID/window-addressed synthesized input. Its bundled `@oai/sky` client is absent from the public npm registry, documents only OpenAI-internal publication, requires the trusted Codex `nodeRepl` runtime, and talks to a peer-code-signature-authorizing local service; never extract, redistribute, or runtime-depend on it. The public Responses API `computer` tool supplies model-authored actions but still requires the caller's own browser/desktop execution harness, so it is not an alternative route to the local driver. Public MIT implementations such as `trycua/cua` and its independently maintained Swift snapshot/rebrand `tropeai/trope-cua` are audit sources, not OpenAI code or drop-in proof: isolate any borrowed mechanism, retain licensing, enumerate private SkyLight/SLPS dependencies, and validate the exact delayed VoiceInk++ route. AXSwift and AXorcist are wrappers, not the full background-focus stack. That broad immediate-action architecture is useful evidence, not runtime proof for VoiceInk++. Preserve VoiceInk++'s narrower delayed exact-input contract and live-test its own target: Computer Use forbids `com.openai.codex`, so never bypass that policy with custom live probes.

## Record only durable verified findings

Record a learning when evidence establishes something likely to affect future work, including a corrected semantic, reproducible failure and root cause, environment constraint, safety boundary, accepted terminology, or reliable validation signal.

Do not record speculation, generic progress, duplicate knowledge, credentials, secrets, raw private configuration, or transient runtime state such as a one-off PID. Commit identities are appropriate when they anchor an accepted implementation.

Keep each field concise but specific enough to prevent rediscovery. Name the symptom, proven cause, actual change, implementation commit, and regression guard. Use logs or user confirmation as evidence only after the behavior is genuinely observed.

## Finish the learning loop

1. Verify the affected behavior with the strongest safe evidence. Background-delivery work must use the required app matrix and preserve `verification=verified`, the exact insertion route, and a safe target/frontmost boundary in the trace; message echo alone is never proof. Keep adjacent behavioral-intent comments current for every non-obvious route, identity check, fallback, and safety boundary; comments should explain the invariant and reason rather than narrate syntax. On the Mac Mini, use the normal Xcode test action with the smallest focused selection that covers the changed regression, the nearest touched contracts, and every mandatory guard named anywhere in `AGENTS.md`; focused scope never overrides those contracts. Prefer the Test navigator. For `xcodebuild -only-testing`, copy the exact current identifier from Xcode or a successful `.xcresult` rather than constructing it, because an unmatched filter can select zero tests without failing the command. In this Swift Testing target, `testName()` executes where `testName` alone selected zero cases in build 335; retain the trailing `()` until a later Xcode-discovered identifier proves otherwise. Require at least one executed test and named output for every expected selection; compilation, a scheme-level `Test Succeeded`, or a zero-test result is not execution. Widen incrementally only when focused failures or shared-code evidence show a broader blast radius. Reserve a full unit-suite run for one final pass at a release boundary, one post-change pass after broad/high-risk architecture work, or a diagnostic pass when focused evidence indicates wider fallout; never run it habitually after ordinary edits or documentation-only changes. The release-boundary pass must cover the exact commit and build number that will be signed and installed. If TestManager stalls during focused iteration, preserve the evidence and retry the focused selection rather than expanding to all tests; never use direct `xcrun xctest` to satisfy a focused selection. At a full-suite gate, the already-built unit-test bundle may run directly with `xcrun xctest` and the app/framework library paths as a bounded fallback, and every expected test must be named. Recover and retry the canonical path when possible, and never enable Developer Mode without Ethan's direction. For every native release, increment `CURRENT_PROJECT_VERSION`, then follow the Mac Mini build, signed-install, five-second restart warning, visible recorder-version label, and live-trace contract in `AGENTS.md`. Build the install candidate with a separate ordinary `xcodebuild build` in fresh DerivedData; never package the app host left by `xcodebuild test`, and reject any candidate containing `*.xctest` or XCTest-named payloads. On the Mini, run its `resign-local.sh` helper with the checked-in local entitlements before archiving; require `VoiceInk Local Signing` on both the outer app and nested `whisper.framework`. Transfer the signed `.app` as an archive stream (or another bundle-preserving archive), never raw recursive `scp`; reject the transfer until local bundle version, deep/strict signature, stable signing authorities, CDHash, and outer Automation entitlement all verify. If a post-build signer replaces the outer app signature, it must explicitly reapply `VoiceInk/VoiceInk.local.entitlements`; verify deep/strict signing and the outer `com.apple.security.automation.apple-events = true` entitlement before accepting Terminal/iTerm support. An ad-hoc app can pass those shallow checks yet abort at launch under dyld library validation, so require the new PID to persist after `open`. A source edit is not a shipped VoiceInk++ change until that uniquely numbered signed build is installed and running. Self-improved — 2026-09-24: build 336's first MacBook launch crashed on an ad-hoc `whisper.framework` despite deep/strict verification; stable-signed build 336 launched.
   Before using an existing test bundle after a timeout, prove compilation completed for the exact candidate. A build number or existing `.xctest` path is insufficient when an uninstalled candidate was edited. If compilation was interrupted, complete `xcodebuild build-for-testing` first, then retry canonical execution without rebuilding; require the newly added tests to be named by the final runner. Bound a stalled TestManager separately from a busy Swift compiler. Self-improved — 2026-09-26: shortened retries left build 350's older 400-test bundle beside source containing 402 tests; see `LEARNINGS.md`, “A timed-out compilation is not a ready test bundle”.
   If that direct full-suite fallback aborts because `MediaRemoteAdapter_MediaRemoteAdapter.bundle` is invisible to the command-line runner, do not count the partial run or alter the built app. Copy the host's `Frameworks` directory to a disposable staging directory, place the host's existing package resource bundle under the staged `MediaRemoteAdapter.framework/Resources`, put the staging directory first in `DYLD_FRAMEWORK_PATH`, and rerun the complete bundle. Require the same named-test and zero-failure checks; this is a runner-resource repair, not permission to patch test code or production resources.
   After a release-boundary suite passes, retain its named logs but remove only that release output's generated Debug test DerivedData and staged framework copy before the separate universal Release build. Never clean unrelated Mini state to make space. Self-improved — 2026-09-25: build 344 reached universal `lipo` with both test and Release caches present and failed for disk capacity; deleting only the completed task-owned test cache let the same Release build succeed.
2. Land the implementation commit before recording its SHA.
   For public distribution, follow `RELEASING.md` and the separate Developer ID/notarization
   verifier rather than the local-signing route. Resolve Sparkle's bare helper through
   `Versions/Current/Autoupdate`, sign it before its framework, and require its Developer ID,
   team, runtime and secure timestamp. Run `python3 scripts/test-release-signing.py` after
   packaging changes; its fixtures need no native build. Self-improved — 2026-09-25: Apple's
   rejection of an unsigned version-B helper established this boundary; see the Sparkle
   entries in `LEARNINGS.md` and `FAILED_APPROACHES.md`.
3. Add the newest entry with:

   `record.sh` inserts immediately below `# Learnings`, above modern dated
   headings. Review that location after each run; a quoted historical
   `(newest first)` marker inside prose is not an insertion point.
   Self-improved — 2026-09-29: a build-384 lesson landed inside a paragraph
   until the insertion anchor and its regression test were corrected.

   ```sh
   bash .agents/skills/learnings/scripts/record.sh \
     --symptom "<observed behavior>" \
     --cause "<verified root cause>" \
     --fix "<changed behavior and files>" \
     --commit "<implementation SHA>" \
     --guard "<test, trace, validator, or invariant>" \
     --trigger "<user request or reproduction>"
   ```

4. Review the inserted entry, then commit the learning separately so it names the reachable implementation commit.
5. If the finding changes reusable workflow, terminology, safety, or validation, update this skill during the same task. Retest changed scripts, then validate with:

   ```sh
   /usr/bin/python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py" \
     .agents/skills/learnings
   ```

   `quick_validate.py` belongs to the system `skill-creator`; it is not duplicated inside this repository skill.
6. If no durable verified lesson emerged, do not add noise.
