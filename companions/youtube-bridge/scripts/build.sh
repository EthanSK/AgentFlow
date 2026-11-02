#!/usr/bin/env bash
# Build or manage the optional Agent Flow Bridge from this portable public checkout.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$repo_root/dist"
extension_dist="$dist_dir/extension"
native_dist="$dist_dir/native-host"
menu_bar_dist="$dist_dir/menu-bar"
menu_bar_app="$menu_bar_dist/Agent Flow Bridge.app"
menu_bar_macos="$menu_bar_app/Contents/MacOS"
menu_bar_resources="$menu_bar_app/Contents/Resources"
codesign_identity="${YOUTUBE_SPOTIFY_MEDIA_KEY_CODESIGN_IDENTITY:--}"

codesign_binary() {
  local target="$1"

  if codesign --force --sign "$codesign_identity" "$target"; then
    return
  fi

  echo "Developer ID signing failed; retrying with local ad-hoc signing for $target" >&2
  codesign --force --sign - "$target" # Bug fix: local installs should still build when Apple's timestamp service does not return a Developer ID timestamp; repro by running scripts/build.sh and seeing "A timestamp was expected but was not found."
}

codesign_app() {
  local target="$1"

  if codesign --force --deep --sign "$codesign_identity" "$target"; then
    return
  fi

  echo "Developer ID app signing failed; retrying with local ad-hoc signing for $target" >&2
  codesign --force --deep --sign - "$target" # Bug fix: same local fallback for the menu app bundle after the native helper has already built.
}

rm -rf "$extension_dist" "$native_dist" "$menu_bar_dist"
mkdir -p "$extension_dist" "$native_dist" "$menu_bar_macos" "$menu_bar_resources"

bash "$repo_root/scripts/package-extension.sh" "$extension_dist"

swiftc \
  "$repo_root/shared/AgentFlowBridgeShared.swift" \
  "$repo_root/native-host/AgentFlowBridgeNativeHost.swift" \
  -o "$native_dist/AgentFlowBridgeHost" \
  -framework AppKit \
  -framework ApplicationServices
codesign_binary "$native_dist/AgentFlowBridgeHost"

cat > "$menu_bar_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>AgentFlowBridge</string>
  <key>CFBundleIdentifier</key>
  <string>com.ethan.youtubeSpotifyMediaKey</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Agent Flow Bridge</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# The checked-in icon keeps normal builds independent of Python/Pillow.
cp "$repo_root/assets/AppIcon.icns" "$menu_bar_resources/AppIcon.icns"

swiftc \
  "$repo_root/shared/AgentFlowBridgeShared.swift" \
  "$repo_root/menu-bar/main.swift" \
  -o "$menu_bar_macos/AgentFlowBridge" \
  -framework AppKit \
  -framework ApplicationServices

codesign_app "$menu_bar_app"

echo "Built extension:"
echo "$extension_dist"
echo
echo "Built native host:"
echo "$native_dist/AgentFlowBridgeHost"
echo
echo "Built menu bar app:"
echo "$menu_bar_app"
