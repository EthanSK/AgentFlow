#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
extension_dist="${1:-$repo_root/dist.noindex/extension}"

# Extension-only updates must not rebuild, remove, sign, or restart the live native bridge.
# Copy the complete source set, including existing local content-script changes and shared artwork.
mkdir -p "$extension_dist/icons"
for extension_file in manifest.json background.js tab-history.js website-opener.js generic-video-router.js generic-rate-bridge.js generic-video.js seek-history.js content-script.js status.html status.css status.js; do
  cp "$repo_root/extension/$extension_file" "$extension_dist/$extension_file"
done
for icon_size in 16 32 128; do
  cp "$repo_root/extension/icons/icon-$icon_size.png" "$extension_dist/icons/icon-$icon_size.png"
done
