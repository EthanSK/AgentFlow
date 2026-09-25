#!/usr/bin/env bash
set -euo pipefail

# First-use only: updates need a recording-idle check, rollback and an installed
# release signature. Refusing an existing bundle is safer than pretending this
# public, ad-hoc build script can perform Ethan's guarded in-place release.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_target="$HOME/Applications/AgentFlow.app"
system_app="/Applications/AgentFlow.app"
legacy_user_app="$HOME/Applications/VoiceInkPlusPlus.app"
legacy_system_app="/Applications/VoiceInkPlusPlus.app"
bridge_app="$HOME/Applications/YouTube Spotify Media Key.app"
bridge_agent="$HOME/Library/LaunchAgents/com.ethan.youtubeSpotifyMediaKey.plist"
bridge_manifest="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.ethan.youtube_spotify_media_key.json"
skill_target="$HOME/.agents/skills/interpret-voiceink-context"
with_bridge=false
with_skill=false
check_only=false

usage() {
  echo "Usage: ./scripts/install-first-use.sh [--all | --with-youtube-bridge] [--with-codex-skill] [--check]"
  echo "Installs a new Agent Flow app into ~/Applications; never replaces an existing app."
  echo "--all adds the optional YouTube Bridge and Codex context skill."
  echo "Chrome extension loading, macOS permissions, provider keys and mouse mapping remain guided steps."
}

wait_for_process() {
  local executable_path="$1"
  local process_name="$2"
  local attempt
  for attempt in 1 2 3 4 5; do
    if pgrep -fl "$process_name" | grep -Fq "$executable_path"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

for option in "$@"; do
  case "$option" in
    --all) with_bridge=true; with_skill=true ;;
    --with-youtube-bridge) with_bridge=true ;;
    --with-codex-skill) with_skill=true ;;
    --check) check_only=true ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Agent Flow requires macOS." >&2
  exit 1
fi

if "$check_only"; then
  for path in "$system_app" "$app_target" "$legacy_system_app" "$legacy_user_app" "$bridge_app" "$bridge_agent" "$bridge_manifest" "$skill_target"; do
    if [[ -e "$path" || -L "$path" ]]; then
      echo "Present: $path"
    else
      echo "Missing: $path"
    fi
  done
  echo "Chrome extension, macOS permissions, provider access and physical mouse buttons need separate verification."
  exit 0
fi

for command in make xcodebuild codesign ditto plutil open; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
done

if [[ -e "$app_target" || -L "$app_target" || -e "$system_app" || -L "$system_app" || \
      -e "$legacy_user_app" || -L "$legacy_user_app" || -e "$legacy_system_app" || -L "$legacy_system_app" ]] || \
   pgrep -x VoiceInkPlusPlus >/dev/null 2>&1 || pgrep -x AgentFlow >/dev/null 2>&1; then
  echo "Agent Flow or VoiceInk++ is already installed or running. This first-use installer will not replace it." >&2
  echo "Use BUILDING.md and the guarded update procedure instead." >&2
  exit 1
fi

if "$with_bridge"; then
  if [[ -e "$bridge_app" || -L "$bridge_app" || -e "$bridge_agent" || -L "$bridge_agent" || \
        -e "$bridge_manifest" || -L "$bridge_manifest" ]] || \
     pgrep -f 'youtube-spotify-media-key-app' >/dev/null 2>&1; then
    echo "The YouTube Bridge is already installed or running. Refusing an in-place companion update." >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 is required by the YouTube Bridge installer." >&2
    exit 1
  fi
fi

if "$with_skill" && [[ -e "$skill_target" || -L "$skill_target" ]]; then
  echo "A personal context skill already exists at $skill_target; refusing to overwrite it." >&2
  exit 1
fi

mkdir -p "$HOME/Applications"
stage_dir="$(mktemp -d "$HOME/Applications/.agentflow-install.XXXXXX")"
candidate="$stage_dir/AgentFlow.app"
echo "Building Agent Flow from this checkout into $stage_dir..."
make -C "$repo_root" local "LOCAL_APP_OUTPUT=$candidate"
if [[ ! -d "$candidate" ]]; then
  echo "Build completed without the expected app bundle: $candidate. Staging directory retained." >&2
  exit 1
fi
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist")"
if [[ "$bundle_id" != "com.ethansk.VoiceInkPlusPlus" ]]; then
  echo "Wrong bundle identifier: $bundle_id" >&2
  exit 1
fi
codesign --verify --deep --strict "$candidate"

if [[ -e "$app_target" || -L "$app_target" ]]; then
  echo "Destination appeared during build. Staged app retained at $stage_dir; no replacement made." >&2
  exit 1
fi
mv "$candidate" "$app_target"
rmdir "$stage_dir"
echo "Installed Agent Flow at $app_target"

if "$with_skill"; then
  mkdir -p "$HOME/.agents/skills"
  ditto "$repo_root/.agents/skills/interpret-voiceink-context" "$skill_target"
  echo "Installed the Codex context skill at $skill_target"
fi

if "$with_bridge"; then
  "$repo_root/companions/youtube-bridge/scripts/install.sh"
  bridge_executable="$bridge_app/Contents/MacOS/youtube-spotify-media-key-app"
  native_host="$repo_root/companions/youtube-bridge/dist/native-host/youtube-spotify-media-key-host"
  extension_dir="$repo_root/companions/youtube-bridge/dist/extension"
  if [[ ! -x "$bridge_executable" || ! -x "$native_host" || ! -f "$extension_dir/manifest.json" || \
        ! -f "$bridge_manifest" || ! -f "$bridge_agent" ]] || \
     ! plutil -lint "$bridge_agent" >/dev/null || \
     ! python3 -m json.tool "$bridge_manifest" >/dev/null || \
     ! launchctl print "gui/$(id -u)/com.ethan.youtubeSpotifyMediaKey" >/dev/null 2>&1 || \
     ! wait_for_process "$bridge_executable" 'youtube-spotify-media-key-app'; then
    echo "YouTube Bridge installation is incomplete. Check its helper, native host and login LaunchAgent; do not treat Chrome playback as verified." >&2
    exit 1
  fi
  echo "YouTube Bridge helper, native host and login LaunchAgent verified. Chrome still needs its unpacked extension loaded."
fi

open -g "$app_target"
if ! wait_for_process "$app_target/Contents/MacOS/AgentFlow" AgentFlow; then
  echo "Agent Flow was installed but did not remain running. The app is at $app_target; check the macOS launch error before recording." >&2
  exit 1
fi
echo "Agent Flow is running from $app_target"
echo
echo "Next: grant Agent Flow Microphone and Accessibility access, add your OpenAI API key for GPT Live, and verify one short recording."
if "$with_bridge"; then
  echo "In Chrome, load $repo_root/companions/youtube-bridge/dist/extension at chrome://extensions and test one disposable YouTube video."
fi
echo "Agentic Mouse and physical mouse mappings are optional and installed/configured separately."
echo "Read SETUP.md for the complete component and acceptance checklist."
