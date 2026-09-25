<div align="center">
  <img src="VoiceInk/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="128" height="128" alt="Agent Flow app icon">

  # Agent Flow

  Speech to text for Mac, built for working with agents.

  [Website](https://ethansk.github.io/AgentFlow/) · [Full setup](SETUP.md) · [Ethan's setup](https://ethansk.github.io/ethan-setup/) · [Build guide](BUILDING.md) · [Button glossary](TERMINOLOGY.md) · [GitHub](https://github.com/EthanSK/AgentFlow)

  [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-066b55.svg)](LICENSE)
  ![Platform: macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-111615.svg)
  ![Swift](https://img.shields.io/badge/Swift-native-4a5452.svg)
</div>

## Real-time context

Highlight text in any app that exposes its selection to macOS, or take a macOS screenshot while recording. The black recorder shows each reference in line with your words: selections in cyan, screenshots in purple. The final paste keeps that approximate order:

```text
Rename this function

<codex_selection index="1" source="Codex" characters="32" middle_omitted="false" truncated="false">
  <text>func loadRows(from cache: Cache)</text>
</codex_selection>

and make the empty state look like this.

<local_screenshot path="/Users/you/Desktop/Screenshot 2026-09-24 at 10.41.12.png"/>
```

- Final `<text>` keeps up to five selected lines or 500 characters, whichever is shorter; `truncated="true"` marks a longer highlight, and `characters` still counts the original selection. The live recorder keeps only a compact preview. Selected text is added after speech recognition, not sent to the real-time speech model. Every separate highlight stays in capture order, even without speech between highlights. A silent run can show the agent what you were reading.
- A highlight from another app uses `<app_selection source="TextEdit" bundle_id="com.apple.TextEdit">` instead of `<codex_selection>`. Chrome can also include a page title, a query-stripped URL (retaining only a validated YouTube video ID), and the selected range's DOM tag/role/label when its on-demand browser script works. Those optional fields are omitted if Chrome blocks scripting; the app name alone does not identify a tab or element. Other apps get only their app identity. Agent Flow never issues Copy to capture a highlight.
- When Codex's active task is provable, a selection also carries its stable `task_id` and current `task_title`. An uncertain task keeps the plain tag; a title alone never identifies a chat.
- VS Code code and diff editors use [Better Git VS Code](https://marketplace.visualstudio.com/items?itemName=EthanSK.better-git-vscode) 1.2.99 or newer as a local selection bridge. It works without screen-reader mode: one fresh mouse highlight is read on demand through a private Unix socket, with no Copy command, network listener or stored text. Terminals, chat webviews, remote extension hosts and multiple simultaneous selections are not covered by this bridge. Its input is capped at 8,192 UTF-16 units before the normal five-line/500-character XML limit, so `characters` can be a lower bound for very large VS Code selections.
- A screenshot contributes its local path, not image pixels or an attachment. The receiving agent needs access to that file.
- Placement is best effort because live recognition can revise earlier words. A highlight can be reading context rather than an instruction.
- Provisional words stay in the recorder until one final paste. The preview grows vertically to the display's safe height, then scrolls.

For Codex to interpret this XML-style context across tasks, install the [Agent Flow context skill](.agents/skills/interpret-voiceink-context/SKILL.md) as a personal skill. You can ask Codex: “Install `interpret-voiceink-context` from `EthanSK/AgentFlow/.agents/skills/interpret-voiceink-context`.” The skill reads interleaved speech, selections and screenshot paths as best-effort context; it does not upload screenshot pixels or assume every highlight is an instruction.

## Choose where each transcript goes

Map two mouse buttons: the **Primary button** to your Agent Flow recording shortcut and the **Next button** to macOS **Next Track**. The [button glossary](TERMINOLOGY.md) lists every alias.

| Press | When | Text goes to |
| --- | --- | --- |
| Primary | While recording | The input focused when the text arrives, like base VoiceInk |
| Next | While recording | The input where you started recording |
| Next | While transcribing, after a Primary stop | **Second chance:** the input focused when you press Next |

Only the Next routes save an exact input together with its app's Mode and auto-send. If Agent Flow can't verify that input, it shows an error instead of pasting somewhere else. The [destination guide](RECORDING_DESTINATIONS.md) has the full contract.

Primary's recording-time double-press finishes to the clipboard with **Won’t paste**; a third press in the same gesture pauses capture, and a fourth finishes with paste but no auto-send. While paused, one fresh press resumes and two finish to the clipboard. These are recording gestures, not extra destinations. Bare Escape stays with the foreground app.

For Codex CLI or Claude Code, the terminal or editor hosting it owns the input, so the recorder shows that host's icon. Set the Mode and auto-send on the host app. No plugin or shell hook is needed.

## Ethan's setup

The [full setup website](https://ethansk.github.io/ethan-setup/) shows Ethan's hardware, mappings and companion apps. [Agentic Mouse](https://ethansk.github.io/agentic-mouse/) is a separate, optional control layer: it can trigger Agent Flow from mouse hardware, but Agent Flow records and transcribes without it.

- **Mouse:** Two spare controls mapped to Agent Flow Primary and macOS Next Track. See the setup site for current device-specific mappings. Next won't skip music while the recorder is showing.
- **Transcription:** GPT Live Transcribe on Ethan's own OpenAI API account; Parakeet is a local fallback.
- **Live words:** shown only in the recorder, then pasted once when you stop.
- **AI:** Optional AI actions and enhancement; fast direct-paste Modes keep enhancement off.
- **Auto-send:** Return in Codex, Claude desktop, ChatGPT and the terminal or editor hosting Codex CLI or Claude Code; off in Chrome.

## Bring your own voice model

Create an [OpenAI API key](https://platform.openai.com/api-keys), enable API billing, and enter that key during Agent Flow setup. A fresh setup with a verified OpenAI key recommends GPT Live Transcribe for live words; a local Parakeet model remains available without a cloud key. Agent Flow stores your key in macOS Keychain and connects directly to OpenAI. There is no Agent Flow account, hosted transcription proxy, subscription, or bundled key. Existing Modes and their model choices are not silently changed by the fresh-install recommendation. Never paste an API key into a chat.

The extra voice-model hints are bounded: your dictionary and a small amount of relevant Codex context can help recognition, but the selected text and screenshot references are assembled into the final message after recognition. [Full setup](SETUP.md) distinguishes the app, key, macOS grants, optional browser bridge, context skill and mouse mapping.

The recorder appears on every connected monitor. Its current-app and locked-destination icons stay separate, and a two-row version/build marker identifies the running native release. Recordings can overlap with earlier transcriptions; each keeps its own Mode, input and delivery state. Genuine delivery errors remain visible.

## YouTube and Chrome companion

The optional [Agent Flow YouTube Bridge](companions/youtube-bridge/README.md) pauses a playing YouTube video when dictation starts and resumes only the video it paused. It also supports Agentic Mouse's YouTube controls, Chrome tab history and website shortcuts. Its extension, macOS helper, tests and install scripts are in this repository; install it separately with the [agent setup guide](companions/youtube-bridge/AGENT_SETUP.md).

## Build from source

There's no public download or Agent Flow Homebrew cask. You need **macOS 14.4 or later**, Xcode and Git.

```sh
git clone https://github.com/EthanSK/AgentFlow.git
cd AgentFlow
./scripts/install-first-use.sh
```

The first-use installer builds an ad-hoc signed app in `~/Applications`, opens it, and refuses to overwrite an existing Agent Flow installation. `./scripts/install-first-use.sh --all` also installs the included YouTube helper, its login LaunchAgent, and the Codex context skill. Chrome extension loading, macOS permissions, provider keys, physical mouse mapping and Agentic Mouse remain separate user choices; see the [full setup and verification guide](SETUP.md). `make local` remains the build-only path that copies an app to `~/Downloads`; [BUILDING.md](BUILDING.md) covers prerequisites and troubleshooting.

The upstream `voiceink` Homebrew cask and downloads install VoiceInk, not Agent Flow.

## Documentation

- [Install the complete, optional-component setup](SETUP.md)
- [Build Agent Flow](BUILDING.md)
- [Translate Ethan's mouse-button terminology](TERMINOLOGY.md)
- [Understand the Next button and recording destinations](RECORDING_DESTINATIONS.md)
- [Read the accepted implementation learnings](LEARNINGS.md)
- [Review failed approaches before retrying delivery work](FAILED_APPROACHES.md)
- [Use the self-improving Codex/Claude Code learnings skill](.agents/skills/learnings/SKILL.md)
- [Install the Agent Flow context interpretation skill](.agents/skills/interpret-voiceink-context/SKILL.md)
- [Review update guidance](UPDATING.md)
- [Agent Flow on GitHub](https://github.com/EthanSK/AgentFlow)

## Origin and license

Agent Flow is Ethan SK's personal fork of [VoiceInk](https://github.com/Beingpax/VoiceInk) by [Pax/Beingpax](https://github.com/Beingpax), shared in public. The native macOS foundation, model integrations and much of the app come from VoiceInk; Agent Flow adds the agent workflow, destination routes, overlapping sessions, recorder UI and delivery hardening. Changes should keep all three routes rather than collapsing them into one toggle.

This fork has no Pro purchase, trial, license validation, affiliate promotion or remote promotional announcements. Paid transcription and AI providers you configure bill you directly.

Licensed under the [GNU General Public License v3.0](LICENSE). VoiceInk and related names belong to their respective owners; Agent Flow is Ethan's independent fork.
