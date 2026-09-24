# Set up VoiceInk++

VoiceInk++ is more than a speech-to-text window: Ethan's fork can combine live speech,
Codex highlights and saved screenshot paths in one dictated message, then deliver the
finished text to the chosen input. The pieces below are deliberately separate so you
can install only what you need. No private API keys, mouse profiles or personal settings
are bundled.

| Piece | Needed for | How to get it |
| --- | --- | --- |
| VoiceInk++ app | Recording, live recorder, transcription and final paste | First-use installer below; macOS 14.4+ and full Xcode |
| Your provider and macOS grants | Actual transcription and input delivery | Add your own provider key or local model; grant Microphone and Accessibility in macOS |
| [Context interpretation skill](.agents/skills/interpret-voiceink-context/SKILL.md) | Helping Codex read the XML-style selection and screenshot references across tasks | Optional installer flag, or ask Codex to install this skill as a personal skill |
| [VoiceInk YouTube Bridge](companions/youtube-bridge/README.md) | Pausing the YouTube tab playing when dictation starts, plus optional Agentic Mouse Chrome controls | Optional installer flag; helper, native host and login LaunchAgent install locally, but Chrome needs one manual extension step |
| [Agentic Mouse](https://ethansk.github.io/agentic-mouse/) | Optional hardware control layer and extra mouse actions | Separate app and setup; not bundled with VoiceInk++ |
| Programmable mouse | Optional hands-free Primary and Next buttons | Map in your own mouse software; VoiceInk++ also works from its keyboard shortcut |

The YouTube helper is the only login LaunchAgent installed by this repository's setup. VoiceInk++
runs as a normal app; its upstream-release check runs inside the app and is notification-only.
The old fork auto-update LaunchAgent is intentionally disabled and is **not** part of setup.

The [VoiceInk++ website](https://ethansk.github.io/VoiceInkPlusPlus/) shows the live-context
workflow. [Ethan's setup](https://ethansk.github.io/ethan-setup/) shows his current hardware
and companion apps; it is an example, not a requirement for your Mac.

## First installation

Use a Mac with full Xcode, Git and internet access for the first dependency build:

```sh
git clone https://github.com/EthanSK/VoiceInkPlusPlus.git
cd VoiceInkPlusPlus
./scripts/install-first-use.sh
```

The script builds a locally signed VoiceInk++ app, verifies its bundle identity and signature,
installs it in `~/Applications`, and opens it. It refuses an existing VoiceInk++ app rather than
overwrite settings or interrupt a recording. It never touches `/Applications/VoiceInk.app`.
It also requires a persistent app process before reporting a successful launch.

For the bundled YouTube companion and Codex context skill too, use
`./scripts/install-first-use.sh --all` **on a first installation only**. You can choose just
`--with-youtube-bridge` or `--with-codex-skill` instead. The read-only `--check` option reports
which local files exist; it does not prove that recording, Chrome or mouse controls work.

If VoiceInk++ is already installed, do **not** use the first-use script. Read
[BUILDING.md](BUILDING.md) for the build/update boundary, preserve a rollback, and update only
when no recording or transcription is active. The companion has its own
[installer and update instructions](companions/youtube-bridge/README.md).

## Finish the parts macOS and Chrome cannot grant for you

1. In VoiceInk++, grant **Microphone** and **Accessibility** when prompted. For exact Terminal or
   iTerm delivery, macOS may also request **Automation** for that host. Do not grant access to a
   different app merely because its name looks similar.
2. Choose a transcription model in each Mode you use and enter **your own** provider key in the
   app. Modes can override the global model. A local model can avoid a cloud provider key.
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
5. If you want physical controls, map one mouse button to VoiceInk++'s configured Primary
   shortcut and another to macOS **Next Track**. Read the [button glossary](TERMINOLOGY.md) and
   [destination guide](RECORDING_DESTINATIONS.md). Install and configure Agentic Mouse separately
   only if you want its additional controls.

## Verify the actual workflow

- Make a short disposable recording. Confirm live words appear in the black recorder and one
  final result pastes where you intended. Test auto-send only in a disposable input.
- While recording, highlight short text in Codex and take a macOS screenshot. Confirm the cyan
  selection and purple screenshot path appear in the recorder and the final message. The receiving
  agent needs local access to the screenshot file to view its pixels.
- If you installed the YouTube Bridge, play a disposable YouTube video, start dictation, and
  confirm that specific video pauses and resumes. An initially paused video must stay paused.
- If you installed Agentic Mouse, test its physical buttons separately. Installing VoiceInk++
  does not program your mouse or prove device-specific shortcuts work.

For a guided agent-assisted setup, use the [companion setup prompt](companions/youtube-bridge/AGENT_SETUP.md)
and tell the agent which optional pieces you actually want. Report app build, app launch, native
host, Chrome extension, skill discovery and physical recording as separate checks; one successful
installer exit is not proof of all six.
