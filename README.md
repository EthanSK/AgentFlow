<div align="center">
  <img src="VoiceInk/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="128" height="128" alt="VoiceInk++ app icon">

  # VoiceInk++

  Speech to text for Mac, built for working with agents.

  [Website](https://ethansk.github.io/VoiceInkPlusPlus/) · [Build guide](BUILDING.md) · [Button glossary](TERMINOLOGY.md) · [Destination guide](RECORDING_DESTINATIONS.md) · [Issues](https://github.com/EthanSK/VoiceInkPlusPlus/issues)

  [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-066b55.svg)](LICENSE)
  ![Platform: macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-111615.svg)
  ![Swift](https://img.shields.io/badge/Swift-native-4a5452.svg)
</div>

## Real-time context

> [!NOTE]
> Real-time context is only in Ethan's current installed build. Public `main` doesn't include it yet, so building this repository won't enable it.

Highlight text in Codex or take a macOS screenshot while you're recording. The recorder shows each one in line with your words, selections in cyan and screenshots in purple, and the final paste puts each reference where you said it:

```text
Rename this function

<codex_selection index="1" source="Codex" characters="32" middle_omitted="false">
  <text>func loadRows(from cache: Cache)</text>
</codex_selection>

and make the empty state look like this.

<local_screenshot path="/Users/you/Desktop/Screenshot 2026-09-24 at 10.41.12.png"/>
```

- Long highlights keep only their first and last 46 characters, as `<start>` and `<end>`.
- Screenshots add their file path, not the image.
- Placement follows the live transcript, so a reference can shift by a word if recognition revises earlier text.
- It's plain text in your message, not a native Codex annotation or a link to an exact range.

## Choose where each transcript goes

Map two mouse buttons: the **Primary button** to your VoiceInk++ recording shortcut and the **Next button** to macOS **Next Track**. The [button glossary](TERMINOLOGY.md) lists every alias.

| Press | When | Text goes to |
| --- | --- | --- |
| Primary | While recording | The input focused when the text arrives, like base VoiceInk |
| Next | While recording | The input where you started recording |
| Next | While transcribing, after a Primary stop | **Second chance:** the input focused when you press Next |

Only the Next routes save an exact input along with its app's Mode and auto-send. If VoiceInk++ can't verify that input, it shows an error instead of pasting somewhere else. Double-pressing Primary pauses and resumes the same recording; it isn't a route. The [destination guide](RECORDING_DESTINATIONS.md) has the full contract.

For Codex CLI or Claude Code, the terminal or editor hosting it owns the input, so the recorder shows that host's icon. Set the Mode and auto-send on the host app. No plugin or shell hook is needed.

## Ethan's setup

- **Mouse:** Logitech G502 X LIGHTSPEED, mapped in Logitech G HUB. Next won't skip music while the recorder is showing.
- **Transcription:** Soniox V5 real-time in English, on your own Soniox account. Keep Deepgram or another model as a fallback.
- **Live words:** shown only in the recorder, then pasted once when you stop.
- **AI:** OpenAI gpt-5.5, with enhancement off in fast direct-paste Modes.
- **Auto-send:** Return in Codex, Claude desktop, ChatGPT and the terminal or editor hosting Codex CLI or Claude Code; off in Chrome.

## Also

- Start a new recording while earlier ones are still transcribing. Each keeps its own Mode, input and delivery state.
- The recorder shows on every connected monitor, with the current app and locked destination as separate icons.
- Double-press Primary to pause and resume one recording. Paused audio is left out.
- The recorder's cancel control discards an active recording. One-shot raw mode skips processing and auto-send.
- Delivery errors show in the recorder instead of being reported as success.

## YouTube and Chrome companion

The optional [VoiceInk YouTube Bridge](companions/youtube-bridge/README.md) pauses a playing YouTube video when dictation starts and resumes only the video it paused. It also supports Agentic Mouse's YouTube controls, Chrome tab history and website shortcuts. Its extension, macOS helper, tests and install scripts are in this repository; install it separately with the [agent setup guide](companions/youtube-bridge/AGENT_SETUP.md).

## Build from source

There's no public download or VoiceInk++ Homebrew cask. You need **macOS 14.4 or later**, Xcode and Git.

```sh
git clone https://github.com/EthanSK/VoiceInkPlusPlus.git
cd VoiceInkPlusPlus
make local
open ~/Downloads/VoiceInkPlusPlus.app
```

`make local` builds an ad-hoc signed app into `~/Downloads`, with no paid Apple Developer account needed. It builds public `main`, which doesn't include real-time context yet. Allow Microphone and Accessibility on first launch; exact Terminal and iTerm delivery also needs Automation. [BUILDING.md](BUILDING.md) covers prerequisites, make targets and troubleshooting.

The upstream `voiceink` Homebrew cask and downloads install VoiceInk, not VoiceInk++.

## Documentation

- [Build VoiceInk++](BUILDING.md)
- [Translate Ethan's mouse-button terminology](TERMINOLOGY.md)
- [Understand the Next button and recording destinations](RECORDING_DESTINATIONS.md)
- [Read the accepted implementation learnings](LEARNINGS.md)
- [Review failed approaches before retrying delivery work](FAILED_APPROACHES.md)
- [Use the self-improving Codex/Claude Code learnings skill](.agents/skills/learnings/SKILL.md)
- [Review update guidance](UPDATING.md)
- [Report a VoiceInk++ issue](https://github.com/EthanSK/VoiceInkPlusPlus/issues)

## Origin and license

VoiceInk++ is Ethan SK's personal fork of [VoiceInk](https://github.com/Beingpax/VoiceInk) by [Pax/Beingpax](https://github.com/Beingpax), shared in public. The native macOS foundation, model integrations and much of the app come from VoiceInk; VoiceInk++ adds the agent workflow, destination routes, overlapping sessions, recorder UI and delivery hardening. Changes should keep all three routes rather than collapsing them into one toggle.

This fork has no Pro purchase, trial, license validation, affiliate promotion or remote promotional announcements. Paid transcription and AI providers you configure bill you directly.

Licensed under the [GNU General Public License v3.0](LICENSE). VoiceInk and related names belong to their respective owners; VoiceInk++ is Ethan's independent fork.
