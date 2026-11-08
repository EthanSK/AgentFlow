# Codex Focus Inspector

A separate background helper with an optional development window. It does not change Agent Flow,
paste text, move the pointer, read message text or store logs. Its only write is
the **Focus that pane's input when I click its chat area** checkbox at the top,
on by default (Ethan, 2026-10-17): after a text-area click in a measured main
or side Conversation region, it sets AXFocused on that pane's `Work with Codex`
input so Codex's remembered input no longer decides where a later paste lands.
When a plain body click leaves the same composer claiming focus, the helper now
renews that exact input's focus through its clicked Conversation and back,
then places the caret instead of skipping it. Chromium ignores a false focus
flag, so that unsupported operation is not used.
Direct clicks in an input, buttons, links and other controls are not reset.
If the original Conversation retakes focus after the existing 0.6-second check,
one bounded attempt can restore that same input. Another click, key press,
app/window change, replaced input or selected draft cancels recovery; no repeated
focus loop or app activation is added. A public key-down count detects newer
typing without reading keys or adding a keyboard listener. These changes address
Ethan's “reset the cursor” request (2026-10-30); visible live Codex acceptance is separate.
A fresh, clearly measured body click now chooses its pane even when an activation
click leaves focus on the other pane's composer or a non-editor control. The helper
re-hit-tests that same point, checks its owner/window/Conversation, then focuses
the clicked pane's input. It preserves other editors and selected/unreadable drafts.
Chromium answers a hit-test at a new point from a coarse cache, so the first read
is often only a window-sized wrapper. Only that answer (or an unavailable one) is
re-read, at most 3 times 40 ms apart, and a newer click or key cancels it. A hit
that stays coarse still stays unknown when an old composer has focus; no region
is guessed. Main chat is recognised by the `AXLandmarkMain` ancestor with no nearer
side tab panel, because its id and class markers have drifted (2026-11-08). Superseding
input cancels the existing hold check in 25 ms slices instead of making the next
click wait through the whole 0.6 seconds. These changes address Ethan's follow-up
of 2026-10-31; they do not prove that every missing visible caret is repaired.
Single, double, triple and modifier-assisted text clicks, plus completed text drags,
all plan input focus (Ethan, 2026-11-06). Highlights retain the existing 300 ms
settling interval so active Agent Flow capture has its usual opportunity to run,
but capture confirmation no longer vetoes focus. This deliberately replaces the
old behavior that preserved an uncaptured selection for a later Agent Flow Start.
The helper no longer observes or stores selection-capture receipts. It never acts
on learned regions, a remembered input or
another app, re-checks focus and frontmost app right before the write, and
reports `verified`, `not confirmed` or the skip reason. The input search is a
bounded last-child-first walk (10 levels, 400 nodes, 0.5 s) inside the clicked
region only. The window can be resized short; its whole content scrolls.
It uses the existing Python/PyObjC runtime; no native app build is required.

## Claude Prompt focus on click

Ethan asked for this on 2026-11-08, after Codex's click-to-input worked. A plain
click on a Claude desktop chat pane puts the caret at the end of that pane's
`Prompt` box. It uses this helper's mouse listener and click worker, the same
**Focus that pane's input** checkbox, and `focus_clicked_pane` in
`claude_prompt_focuser.py`.

- Only plain single clicks count. A drag, a double or triple click, or a click
  with a modifier key does nothing, because moving focus would clear text just
  selected to copy. Codex differs here because Ethan asked for highlights there.
- A click on a button, link, menu item or text field, or outside a chat pane such
  as the sidebar, does nothing. Another text input that holds the caret keeps it.
- A newer click or key press cancels the attempt. The only writes are AXFocused
  and the end-of-draft caret. The log gets one `claude prompt focus · click`
  status line per plain click, never message text.
- Agents cannot check this live because Computer Use refuses Claude's own window.
  Fixture tests cover the logic; Ethan's real clicks are the live check.

## Claude Prompt focus on Agent Flow stop (disabled)

Disabled by Ethan later on 2026-10-19 (`ENABLED = False` in `claude_prompt_focuser.py`):
it never fired live. Typing-only Agent Flow sessions post no `recordingStopped`, so
the trigger misses Ethan's usual typed Claude messages. The description below is
the dormant design; re-enable only with a trigger that also covers typing.

Second write, approved by Ethan on 2026-10-19 (checkbox **Focus
Claude's Prompt box when Agent Flow stops recording**). Agent Flow's Primary
finish pastes into whatever has keyboard focus, and Claude desktop drops the
paste once a click on its conversation or a button has taken focus off the
composer (Codex instead routes a paste to its remembered input). On Agent Flow's
`com.ethansk.voiceink.recordingStopped` broadcast, and only while Claude
(`com.anthropic.claudefordesktop`) is frontmost, `claude_prompt_focuser.py` finds
the `AXTextArea` named `Prompt` inside the `AXGroup` whose name ends in ` pane`
(measured on Claude 2.42304.0: `Primary pane`) that holds focus, then writes
AXFocused once and places the caret at the end of any draft. It skips when the
Prompt is already focused, another text input has focus, focus moves during the
lookup, or a split view has no focused pane. Every finish posts that broadcast,
including cancel and the clipboard-only "Won't paste" finish, so those also move
focus into the Prompt. The log gets one `claude prompt focus` status line per
stop, never message text. Agent Flow's own delivery is unchanged.

Run `python3 inspector.py` from this directory on a Mac with PyObjC/AppKit and
Quartz installed. It starts hidden; it does not open a window at login or after a
restart. `python3 inspector.py --show-inspector` opens the **Live** window on the
built-in MacBook display only, reusing the existing background process. Closing
the window or pressing Command-W hides it without stopping pane focusing.
`--hide-inspector` hides the window; `--status` reports only process/readiness/window
state plus its own current Accessibility permission, never click samples.
Status also includes text-free runtime counters, listener generation, pause/focus
switches, actual mouse-tap enablement, worker/watchdog liveness and failure counts.
A fresh reply is required: an old lock-file PID is
not proof that the helper is responding. `--reconnect` explicitly rearms the
existing helper's event sources and returns a fresh reply; it fails if no helper
is running or the control request receives no reply.
Running/ready does not mean permission is granted. Explicit `--quit` stops the helper. A per-user file
lock prevents two live instances from both writing focus. Demo has its own lock.
`python3 inspector.py --demo` is for synthetic UI tests; it never creates an AX
reader or event monitor and deliberately ignores clicks outside its own buttons.
Add `--background` to start Demo hidden for lifecycle tests.

The user LaunchAgent is `~/Library/LaunchAgents/com.ethansk.agentflow.codex-focus-helper.plist`.
It starts hidden at login and restarts abnormal exits, not an explicit Quit.
`launch_agent.py` renders its configuration; pass the intended stable Python
executable when generating it. Logs in `~/Library/Logs/AgentFlow/` contain lifecycle
messages only. Runtime locks are under `~/Library/Application Support/AgentFlow/CodexFocusHelper/`.
The helper is Python application code, not a Codex or Claude skill.

The existing mouse and distributed-notification listeners are re-registered
when macOS wakes, the user session becomes active, or a local Codex/ChatGPT app
launches. Old listeners are removed first and pending clicks
are invalidated. This lifecycle path adds no continuous scan, extra helper or
focus write; it preserves Pause and the focus switches. Self-health checks below
also cover failures between lifecycle events.
The Oct 27 failure was an alive but nonresponsive old process, whose status
replies recovered after restart. The exact OS event that broke its subscriptions
was not captured; lifecycle re-registration is prevention, not proof of that trigger.

## Own-process health and failure recovery

The single mouse observer is a public **listen-only CGEvent tap**. It never
consumes or posts events. Left clicks use the existing pane pipeline; right/other
mouse-down only cancels old focus work. Disabled-tap notifications re-enable it;
the self-health check can also see actual disabled/unavailable state. A missing
tap retries without prompting, backing off to at most once per minute. Queued
callbacks from an older listener generation are ignored.

A five-second timer checks only this helper's own listener and distributed-control
self-ping. One missed reply rearms sources; a second missed reply exits the helper
with failure so the existing LaunchAgent starts one clean instance. A lightweight
watchdog thread checks active-worker and main-loop progress. A worker request over
six seconds, a dead worker, three consecutive unexpected worker exceptions, or an
unresponsive main loop exits this helper instead of spawning replacement AX threads.
Sleep/scheduling gaps get a resume grace period. Lack of clicks is never a failure.
An activity token keeps the interactive observer responsive while allowing normal
system sleep. None of these health checks reads an app's focus or chat tree.

Recovery evidence is limited to the last 16 private, text-free receipts in
`CodexFocusHelper/live/health-events.json` (timestamp, reason, counts and durations).
There is no extra process, chat-scanning timer, keyboard monitor, repeating focus retry or
change to Agent Flow/Model Bar. A deliberate Quit remains stopped. The hidden
helper's size-one request queue and one worker are preserved. Explicit Pause and
focus-switch choices are saved privately and restored after a helper restart.

Before each focus/caret write, a current request, frontmost PID and original
window are required. A new mouse-down, Pause, a focus-switch change, a reconnect,
or a different window cancels stale work. A nonempty or unreadable input selection
is never collapsed by caret placement. Text selection itself no longer vetoes
the requested pane focus; direct input and interactive-control clicks stay native.

There is no repeating UI-result timer. A size-one worker queue sleeps until a
click arrives. Completed results are coalesced into one main-loop callback;
hidden windows do not render them. At most one pending result and the last 20
diagnostic snapshots are retained. The separate post-write focus verification
still waits at most 200 ms; only the one same-Conversation recovery described above can repeat the focus write. This is not a
continuous scan of Codex. Memory/runtime costs should be measured, not inferred
from the absence of polling.

Click the main input, side input, then each chat body yourself. The viewer shows
**Clicked pane**, **Focused pane** and **Editable input focused** / **No editable
input focused** separately, plus Same pane, Different panes, Different windows,
or Not enough evidence. Clicking a Conversation region can identify its pane
without claiming that its input has focus. The event counter distinguishes
no received click from an Unknown classification. This is a snapshot after mouse
release plus 90 ms, not continuous keyboard focus tracking; Tab is not monitored.
A public AXIdentifier/AXDOMIdentifier containing an explicit main-chat/side-chat
marker can identify a pane. The measured ChatGPT.app 26.1013.31256 / 20586 profile
also recognises a Conversation region under a `-chat-panel` container (Main chat)
or `app-shell-tab-panel-app-shell-tab:<number>` AXTabPanel (Side chat).
ChatGPT.app 26.1103.41825 / 25679's bundled frontend no longer includes the old
`-chat-panel` main marker. That build's main-content portal instead has the exact
`@container/app-shell-main-content` class. The reader checks the public
`AXDOMClassList` on the existing ancestor path after finding a Conversation and
retains only a Boolean marker, never arbitrary class names. The nearest side
scope still wins over an enclosing main scope. This source-backed marker support
has synthetic regression coverage; real Codex click-to-caret acceptance is separate.
These structural checks apply to both local `ChatGPT.app` and `Codex.app` independently
of their release version. Version metadata is diagnostic only: an app update
must not disable an unchanged pane structure. Unknown hosts remain excluded,
and a changed or missing Conversation/panel structure still produces no focus
action. A generic panel without a
Conversation region is not identified as a side chat. The metadata lists at most
48 elements, not a full chat-tree scan. Focus uses the click owner's app element,
not the failing system-wide focus query, and rechecks the same element and active
app. Editable input additionally requires a confirmed editable leaf and bounds.
A pane outline or clicked message alone is not that evidence.
If a hit-test returns only a window-sized wrapper, a freshly focused Conversation
region in the same window can identify the click only when its own bounds contain
the captured click. A remembered input, a different window or stale focus cannot
supply that fallback. The UI labels this different evidence explicitly.
All reads run on a worker, with a per-path 0.85-second budget checked at each
attribute, including a reserved final focus recheck, not the HUD. Incomplete
ancestors retain safe evidence with an explicit partial-path warning only when
window identity/bounds and (for focus) the same focused element are verified.
Unknown, missing permission, other-app focus, cycles and timeouts remain explicit;
there is no retry/poll loop, click or paste; the only descendant walk and write
are the opt-in input focus described above.

If there is no explicit marker, choose an ancestor container and label it Main
chat or Side chat. Subsequent hits inside that region are marked **Learned
region**, not semantic detection. Calibration is process/window/layout-specific,
never saved, and invalid after moving/resizing the window. The labelled container
must also match the fresh ancestor path, so a moved inner divider invalidates it.
Overlap is Unknown. Focused input bounds must fit entirely within that container;
the earlier click location can never substitute for input geometry.
Pick a container enclosing the pane, not a word, a message or the whole window.
This experiment does not prove that activating a composer will be safe or that a
later paste will arrive there. It never becomes a production paste target.

Accessibility permission may be needed for the Python host. The settings button
only opens the normal settings page when clicked; nothing changes TCC or prompts
automatically. No keyboard monitoring, Screen Recording, network access or saved
chat data is needed. Pause stops new sampling; Clear forgets samples and labels;
Quit stops the helper; the close button or ⌘W only hides its window. The shortcut is local to its
key window and never intercepts shortcuts in another app. No native Agent Flow
build, update or restart is needed.

Permission inherited from Codex when launching in its terminal is not proof that
the independent LaunchAgent has permission. Use `--status` after startup; an
`accessibility: false` result needs the user's approval for the Python helper.
With the user's explicit approval, `--request-accessibility` requests that access
from the running service itself; normal startup and status never prompt.
Do not reset TCC or copy another app's identity. Permission changes require no
poller: each click checks permission again, and an explicit status request asks
the live process for its current state.

## Learn From a Failed Read

- Check **Live**, not Demo, and **Pause**, not Resume. Resume means paused.
- If received clicks stay zero, inspect monitor/access state before changing the
  pane classifier. Opening settings does not grant permission automatically.
- If clicks arrive but remain Unknown, compare the two reasons: no public pane
  marker is different from an unreadable or non-editable focused element.
- Click an actual input before blaming selection capture. The optional measured
  body-click focuser is separate from pane recognition and must confirm its write.
- Copy diagnostics after reproducing. Only the last 20 snapshots are retained in
  memory. Copy exports roles, availability/counts, app version, failure codes,
  timings, safe marker-presence flags, partial-path/focus-recheck states and
  classifications, not message values, raw IDs, titles, paths or coordinates.
  Earlier misses keep their original classification after teaching.
- Do not infer main/side from the most recent active chat event, left/right
  position, whole-window geometry, or a successful API return. A safe production
  fix needs separate exact pane-to-composer proof and end-to-end acceptance.

This is for Ethan's own interactive inspection, not an agent automation interface
or a workaround for a Computer Use refusal. Do not capture/read its live Codex
output as an agent or automate Codex through it unless Ethan explicitly asks for
a live verification pass and Computer Use grants the app. Use fixtures otherwise.

Validate with `python3 -m unittest -v test_pane_model test_ax_reader test_shortcuts test_pane_focuser test_claude_prompt_focuser test_helper_runtime` on the Mini,
and exercise the
disposable Demo UI without inspecting live Codex. Synthetic evidence is not live
Codex acceptance. The helper has no effect on the installed native Agent Flow.
The fake-AX adapter tests cover deep paths, the app-owned focus query, partial
reads, the reserved recheck, changed focus/app, and balanced reference releases;
they never contact the live Accessibility tree. Demo also includes Chat area and
Partial read cases. Leave **Live**, never Demo, as the user-operated handoff.
