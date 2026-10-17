# Codex Focus Inspector

A separate, user-operated read-only development window. It does not change Agent
Flow, paste text, move the pointer, set focus, read message text or store logs.
It uses the existing Python/PyObjC runtime; no native app build is required.

Run `python3 inspector.py` from this directory on a Mac with PyObjC/AppKit and
Quartz installed. The **Live** window opens on the built-in MacBook display only.
`python3 inspector.py --demo` is for synthetic UI tests; it never creates an AX
reader or event monitor and deliberately ignores clicks outside its own buttons.

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
or `app-shell-tab-panel-app-shell-tab:<number>` AXTabPanel (Side chat). Other
host/version tuples do not inherit that assumption. A generic panel without a
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
there is no retry/poll loop, descendant scan, focus write, click or paste.

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
Quit or ⌘W in the inspector closes the helper. The shortcut is local to its
key window and never intercepts shortcuts in another app. No native Agent Flow
build, update or restart is needed.

## Learn From a Failed Read

- Check **Live**, not Demo, and **Pause**, not Resume. Resume means paused.
- If received clicks stay zero, inspect monitor/access state before changing the
  pane classifier. Opening settings does not grant permission automatically.
- If clicks arrive but remain Unknown, compare the two reasons: no public pane
  marker is different from an unreadable or non-editable focused element.
- Click an actual input before blaming selection capture. Clicking chat content
  can leave another composer remembered/focused; this viewer never fixes it.
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
output as an agent or automate Codex through it. Use fixtures for validation.

Validate with `python3 -m unittest -v test_pane_model test_ax_reader test_shortcuts` on the Mini,
and exercise the
disposable Demo UI without inspecting live Codex. Synthetic evidence is not live
Codex acceptance. The helper has no effect on the installed native Agent Flow.
The fake-AX adapter tests cover deep paths, the app-owned focus query, partial
reads, the reserved recheck, changed focus/app, and balanced reference releases;
they never contact the live Accessibility tree. Demo also includes Chat area and
Partial read cases. Leave **Live**, never Demo, as the user-operated handoff.
