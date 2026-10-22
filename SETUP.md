# Set up Agent Flow

Agent Flow pastes your speech with mouse highlights from supported Mac apps and saved screenshot
paths, in approximate speaking order. Install the app first, then choose any extras below.
No private API keys, mouse profiles or personal settings are bundled.

| Piece | Needed for | How to get it |
| --- | --- | --- |
| Agent Flow app | Recording, live recorder, transcription and final paste | [Notarized Mac download](https://github.com/EthanSK/AgentFlow/releases/download/v2.0.458/AgentFlow-v2.0.458-mac-universal.zip); macOS 14.4+. Xcode is only needed to build from source. |
| Your OpenAI API key and macOS grants | Recommended GPT Live transcription and input delivery | Create an [OpenAI API key](https://platform.openai.com/api-keys), enable API billing, then grant Microphone and Accessibility in macOS. A local Parakeet model remains available. |
| [Context interpretation skill](.agents/skills/interpret-agent-flow-context/SKILL.md) | Helping local Codex and Claude Code read selection and screenshot references | Run the standalone skill installer below, before or after installing the app |
| [Agent Flow YouTube Bridge](companions/youtube-bridge/README.md) | Pausing the YouTube tab playing when dictation starts, plus optional Agentic Mouse Chrome controls | Use the companion's own installer after installing the app download; Chrome needs one manual extension step |
| [Agentic Mouse](https://ethansk.github.io/agentic-mouse/) | Optional hardware control layer and extra mouse actions | Separate app and setup; not bundled with Agent Flow |
| [Better Git VS Code](https://marketplace.visualstudio.com/items?itemName=EthanSK.better-git-vscode) 1.2.99+ | Mouse highlights in local code editors; code-editor use is confirmed, while diff editors have isolated-test coverage only | Install from the VS Code Marketplace and activate the updated extension; no extra LaunchAgent or permission grant |
| Programmable mouse | Optional hands-free Primary and Next buttons | Map in your own mouse software; Agent Flow also works from its keyboard shortcut |

The YouTube helper is the only login LaunchAgent installed by this repository's setup. Agent Flow
runs as a normal app; its optional update check reads only this repository's Agent Flow releases and is notification-only.
The old fork auto-update LaunchAgent is intentionally disabled and is **not** part of setup.

The [Agent Flow website](https://ethansk.github.io/AgentFlow/) shows the live-context
workflow. [Ethan's setup](https://ethansk.github.io/ethan-setup/) shows his current hardware
and companion apps; it is an example, not a requirement for your Mac.

## First installation

Download [Agent Flow v2.0.458](https://github.com/EthanSK/AgentFlow/releases/download/v2.0.458/AgentFlow-v2.0.458-mac-universal.zip), unzip it and move `AgentFlow.app` to Applications. The universal app is Developer ID signed, Apple notarized and stapled. Open it and finish the permissions and model setup below. [Release checksums](https://github.com/EthanSK/AgentFlow/releases/tag/v2.0.458) are public.

For an update, finish any recording/transcription, quit the app, and keep a ZIP of the previous app as rollback before replacing it. Do not delete Agent Flow's settings, Keychain entries or recordings. Updates are manual; optional daily checks notify you about this repository's releases, never replace the app or install upstream VoiceInk.

To check a download, put the ZIP and `SHA256SUMS` from that release in the same folder, then run `shasum -a 256 -c SHA256SUMS` there. A matching checksum verifies the download; macOS separately checks the signature and notarization.

### Add optional extras after installing the download

The ZIP contains the app only. Do not run `install-first-use.sh --all` after installing it:
that source-build installer deliberately refuses an existing app, even when an extras flag
is supplied.

- **Codex and Claude Code context skill:** clone the source once and run:

  ```sh
  git clone https://github.com/EthanSK/AgentFlow.git
  cd AgentFlow
  python3 scripts/install-context-skill.py
  python3 scripts/install-context-skill.py --check
  ```

  This needs Python 3, not a native app build. It installs one canonical folder at
  `~/.agents/skills/interpret-agent-flow-context`, with links from `~/.codex/skills`
  and `~/.claude/skills`. It refuses to replace existing different skills or links.
  Start a new Codex or Claude Code session to refresh its skill list. No global hooks,
  settings changes, API keys or background service are installed. The weekly skill
  update check asks before applying an available update and preserves local changes.
  Cloud ChatGPT and Claude Desktop do not load these local skill folders; they need
  the full inline context or an uploaded file, not a Mac-only file link.
- **YouTube Bridge:** clone this repository into a folder you will keep, then follow the
  [companion's requirements and installer](companions/youtube-bridge/README.md#requirements-and-standalone-source).
  Run `./companions/youtube-bridge/scripts/install.sh` from the repository root. This builds
  and installs only the helper, native host and login LaunchAgent; it does not rebuild or
  replace Agent Flow. It needs Apple Command Line Tools and Python 3, then one manual
  unpacked-extension load in Chrome. Full Xcode is not required for this companion.

### Build from source instead

Use a Mac with full Xcode (including the SDKs listed in [BUILDING.md](BUILDING.md)),
CMake 3.28+, Git and internet access for the first dependency build:

```sh
git clone https://github.com/EthanSK/AgentFlow.git
cd AgentFlow
./scripts/install-first-use.sh
```

The script builds a locally signed Agent Flow app, verifies its bundle identity and signature,
installs it in `~/Applications`, and opens it. It refuses an existing Agent Flow or VoiceInk++ app rather than
overwrite settings or interrupt a recording. It never touches `/Applications/VoiceInk.app`.
It also requires a persistent app process before reporting a successful launch.

For the bundled YouTube companion and Codex context skill too, use
`./scripts/install-first-use.sh --all` **on a first installation only**. You can choose just
`--with-youtube-bridge` or `--with-codex-skill` instead. The read-only `--check` option reports
which local files exist; it does not prove that recording, Chrome or mouse controls work.

If Agent Flow is already installed, do **not** use the first-use script. Read
[BUILDING.md](BUILDING.md) for the build/update boundary, preserve a rollback, and update only
when no recording or transcription is active. The companion has its own
[installer and update instructions](companions/youtube-bridge/README.md).

## Finish the parts macOS and Chrome cannot grant for you

1. In Agent Flow, grant **Microphone** and **Accessibility** when prompted, then choose your
   microphone. Screen Recording is needed only for capture features that request it.
   Review the device before recording; changing system output to a speaker is not a request to
   change your input. Do not grant access to a different app merely because its name looks similar.
2. Create an [OpenAI API key](https://platform.openai.com/api-keys), enable API billing, and enter
   **your own** key during Agent Flow setup. The app saves it in macOS Keychain and recommends
   GPT Live Transcribe for a fresh setup. Agent Flow calls OpenAI directly: there is no Agent Flow
   account, hosted transcription proxy or subscription. Modes can override the global model.
   Setup also downloads a local Parakeet model, which can transcribe without a cloud key.
   [API usage is billed separately from ChatGPT](https://help.openai.com/en/articles/9039756).
   Never paste an API key into a chat. Auto-send starts off; turn it on per app in Modes if you want
   Return pressed after paste. Check the sound settings too: fresh defaults mute system output
   while recording and pause media on built-in speakers.
3. If you installed the YouTube Bridge, open `chrome://extensions`, enable Developer mode, load
   `companions/youtube-bridge/dist/extension` as an unpacked extension, then reload the YouTube
   tabs you want it to control. The expected extension ID is `kjcofljkanbdomkahdicnibojcoagmjl`.
   The helper's login LaunchAgent is `com.ethan.youtubeSpotifyMediaKey`; the native host is
   registered for that extension ID. The installer cannot silently approve Chrome's unpacked
   extension for you. Keep the checkout in place: Chrome's native-host registration and unpacked
   extension point into its `dist/` directory.
4. If you installed the context skill, use a new Codex task or ask Codex to reload skills if it
   does not appear. The skill helps an agent interpret inline references; screenshot tags still
   contain **paths**, not uploaded image pixels.
5. If you want physical controls, map a mouse button to Agent Flow's configured Primary
   shortcut. Saved-input Next routes are currently disabled; normal finish uses the keyboard-focused input.
   Read the [button glossary](TERMINOLOGY.md) and
   [destination guide](RECORDING_DESTINATIONS.md). Install and configure Agentic Mouse separately
   only if you want its additional controls.
6. For optional Chrome page details with selected text, enable **View → Developer → Allow
   JavaScript from Apple Events** in Chrome. Grant Agent Flow Automation access if macOS asks.
   Without browser scripting, selection capture can still use macOS Accessibility, but page
   title, URL and element details may be omitted.

## Verify the actual workflow

- Make a short disposable recording. Confirm live words appear in the black recorder and one
  final result pastes where you intended. Test auto-send only in a disposable input.
- While recording, mouse-highlight short text first in Codex, then in a disposable TextEdit document,
  and save a macOS screenshot to a file, not just the clipboard. Confirm both cyan selections and the purple screenshot path appear
  in capture order in the recorder and final message. Highlights use `<app_selection>`
  with their source app. Selection text is kept in full with whitespace intact, while the recorder shows a short preview.
  Some source apps impose their own limits before Agent Flow receives the text.
  Each separate highlight remains in order even if you speak nothing between them. Chrome can
  add page and DOM cues when browser scripting is available. Other apps work on a best-effort basis
  when they expose selected text through read-only macOS APIs. The receiving
  agent needs local access to the screenshot file to view its pixels.
- If you installed the YouTube Bridge, play a disposable YouTube video, start dictation, and
  confirm that specific video pauses and resumes. An initially paused video must stay paused.
- If you installed Agentic Mouse, test its physical buttons separately. Installing Agent Flow
  does not program your mouse or prove device-specific shortcuts work.
- For VS Code, start recording and drag-select text in a disposable code editor, then a diff.
  Confirm each selection appears in the recorder and final `<app_selection>` message.
  Better Git's optional bridge reads a fresh selection in the focused editor, including drag,
  Shift-click and Command-A;
  automatic Git hunk navigation and stale selections are ignored. Terminals/chat webviews
  still depend on their own Accessibility exposure, not the code-editor bridge.

### App support is best effort

Codex, Chrome and VS Code code-editor highlights have user-confirmed examples. The VS Code
diff bridge has isolated Mac test coverage, not everyday-use acceptance. Telegram's native selected
text is not reliably exposed: the optional highlight-area image fallback asks for consent and is
not exact selected text. Other apps depend on their read-only Accessibility selection exposure;
not every rendered control or app supports it. Mouse and supported keyboard-selection gestures
are captured, but source-app limitations still apply.

Automatic paste includes highlights and screenshot paths only in the native Codex/ChatGPT,
Telegram and Claude apps. Browsers, editors and terminals receive spoken/typed prose without those tags.
Clipboard-only finishes keep the full context; raw/skip and assistant follow-up output omit it.
Click **Click to type** in the recorder to add typed words alongside speech and references; Enter
commits the typed section at the current observed speech position without stopping capture.
Shift+Enter adds a line break; Command+Enter finishes and sends. The normal finish action
pastes the message, with any still-open typing placed after the final speech.
Live recognition can revise earlier words, so XML position is an
approximate reading/speaking trail, not a precise timestamp.

For a guided agent-assisted setup, use the [companion setup prompt](companions/youtube-bridge/AGENT_SETUP.md)
and tell the agent which optional pieces you actually want. Report app build, app launch, native
host, Chrome extension, skill discovery and physical recording as separate checks; one successful
installer exit is not proof of all six.
