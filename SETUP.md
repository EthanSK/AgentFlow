# Set up Agent Flow

Agent Flow is more than a speech-to-text window: Ethan's fork can combine live speech,
highlights from supported Mac apps and saved screenshot paths in one dictated message, then deliver the
finished text to the chosen input. The pieces below are deliberately separate so you
can install only what you need. No private API keys, mouse profiles or personal settings
are bundled.

| Piece | Needed for | How to get it |
| --- | --- | --- |
| Agent Flow app | Recording, live recorder, transcription and final paste | First-use installer below; macOS 14.4+ and full Xcode |
| Your OpenAI API key and macOS grants | Recommended GPT Live transcription and input delivery | Create an [OpenAI API key](https://platform.openai.com/api-keys), enable API billing, then grant Microphone and Accessibility in macOS. A local Parakeet model remains available. |
| [Context interpretation skill](.agents/skills/interpret-voiceink-context/SKILL.md) | Helping Codex read the XML-style selection and screenshot references across tasks | Optional installer flag, or ask Codex to install this skill as a personal skill |
| [Agent Flow YouTube Bridge](companions/youtube-bridge/README.md) | Pausing the YouTube tab playing when dictation starts, plus optional Agentic Mouse Chrome controls | Optional installer flag; helper, native host and login LaunchAgent install locally, but Chrome needs one manual extension step |
| [Agentic Mouse](https://ethansk.github.io/agentic-mouse/) | Optional hardware control layer and extra mouse actions | Separate app and setup; not bundled with Agent Flow |
| [Better Git VS Code](https://marketplace.visualstudio.com/items?itemName=EthanSK.better-git-vscode) 1.2.99+ | Mouse highlights from local VS Code code and diff editors, even with screen-reader mode off | Install from the VS Code Marketplace and activate the updated extension; no extra LaunchAgent or permission grant |
| Programmable mouse | Optional hands-free Primary and Next buttons | Map in your own mouse software; Agent Flow also works from its keyboard shortcut |

The YouTube helper is the only login LaunchAgent installed by this repository's setup. Agent Flow
runs as a normal app; its upstream-release check runs inside the app and is notification-only.
The old fork auto-update LaunchAgent is intentionally disabled and is **not** part of setup.

The [Agent Flow website](https://ethansk.github.io/AgentFlow/) shows the live-context
workflow. [Ethan's setup](https://ethansk.github.io/ethan-setup/) shows his current hardware
and companion apps; it is an example, not a requirement for your Mac.

## First installation

Use a Mac with full Xcode, Git and internet access for the first dependency build:

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

1. In Agent Flow, grant **Microphone** and **Accessibility** when prompted. For exact Terminal or
   iTerm delivery, macOS may also request **Automation** for that host. Do not grant access to a
   different app merely because its name looks similar.
2. Create an [OpenAI API key](https://platform.openai.com/api-keys), enable API billing, and enter
   **your own** key during Agent Flow setup. The app saves it in macOS Keychain and recommends
   GPT Live Transcribe for a fresh setup. Agent Flow calls OpenAI directly: there is no Agent Flow
   account, hosted transcription proxy or subscription. Modes can override the global model.
   A local Parakeet model can transcribe without a cloud key. Never paste an API key into a chat.
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
5. If you want physical controls, map one mouse button to Agent Flow's configured Primary
   shortcut and another to macOS **Next Track**. Read the [button glossary](TERMINOLOGY.md) and
   [destination guide](RECORDING_DESTINATIONS.md). Install and configure Agentic Mouse separately
   only if you want its additional controls.

## Verify the actual workflow

- Make a short disposable recording. Confirm live words appear in the black recorder and one
  final result pastes where you intended. Test auto-send only in a disposable input.
- While recording, highlight short text first in Codex, then in a disposable TextEdit document,
  and take a macOS screenshot. Confirm both cyan selections and the purple screenshot path appear
  in capture order in the recorder and final message. The Codex highlight uses
  `<codex_selection>`; TextEdit uses `<app_selection source="TextEdit">`. Selection text is bounded
  to five lines or 500 characters in the final message, while the recorder shows a short preview.
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
  Better Git's optional bridge reads only a fresh mouse selection in the focused editor;
  automatic Git hunk navigation and stale selections are ignored. Terminals/chat webviews
  still depend on their own Accessibility exposure, not the code-editor bridge.

For a guided agent-assisted setup, use the [companion setup prompt](companions/youtube-bridge/AGENT_SETUP.md)
and tell the agent which optional pieces you actually want. Report app build, app launch, native
host, Chrome extension, skill discovery and physical recording as separate checks; one successful
installer exit is not proof of all six.
