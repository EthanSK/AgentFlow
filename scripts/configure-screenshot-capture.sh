#!/usr/bin/env bash
set -euo pipefail

# Agent Flow can attach only screenshots saved before the recording finishes.
# Configure macOS itself; no watcher, process restart or transcription wait.
case "${1:-}" in
  --check|"") ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--check]" >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo "Agent Flow requires macOS." >&2; exit 1; }

current="$(defaults read com.apple.screencapture show-thumbnail 2>/dev/null || true)"
if [[ "$current" == 0 ]]; then
  echo "Screenshot immediate saving: ready (Show Floating Thumbnail is off)."
  exit 0
fi
if [[ "${1:-}" == --check ]]; then
  echo "Screenshot immediate saving: not configured (Show Floating Thumbnail is on or unset)."
  exit 1
fi

# Write only this key. Preserve the user's folder, image type and other options.
defaults write com.apple.screencapture show-thumbnail -bool false
[[ "$(defaults read com.apple.screencapture show-thumbnail)" == 0 ]] || {
  echo "Could not verify the screenshot setting." >&2
  exit 1
}
echo "Show Floating Thumbnail is off so screenshots save immediately."
echo "To restore it: defaults write com.apple.screencapture show-thumbnail -bool true"
