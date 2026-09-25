#!/usr/bin/env bash
set -euo pipefail

# This is the public-download gate, not the local AgentFlow signing check.
# A locally trusted self-signed app must never be presented as a Gatekeeper-ready release.
app=${1:?Pass the staged AgentFlow.app path}
test -d "$app"

plist="$app/Contents/Info.plist"
test -f "$plist"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
test "$bundle_id" = com.ethansk.VoiceInkPlusPlus
[[ "$build" =~ ^[1-9][0-9]*$ ]]
test -x "$app/Contents/MacOS/$executable"

if find "$app/Contents" \( -name '*.xctest' -o -name '*XCTest*' \) -print -quit | grep -q .; then
  echo 'Public release contains a test payload; use a separate clean build.' >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app"
signature=$(codesign --display --verbose=4 "$app" 2>&1)
grep -Fq 'Authority=Developer ID Application:' <<<"$signature"
grep -Fq 'TeamIdentifier=T34G959ZG8' <<<"$signature"
grep -Eq 'flags=.*runtime' <<<"$signature"
grep -Fq 'Timestamp=' <<<"$signature"

entitlements=$(codesign --display --entitlements :- "$app" 2>/dev/null | plutil -p -)
grep -Fq '"com.apple.security.automation.apple-events" => true' <<<"$entitlements"
test "$(wc -l <"$app/Contents/Resources/COPYING" | tr -d ' ')" -ge 600

whisper="$app/Contents/Frameworks/whisper.framework"
test -d "$whisper"
whisper_signature=$(codesign --display --verbose=4 "$whisper" 2>&1)
grep -Fq 'Authority=Developer ID Application:' <<<"$whisper_signature"
grep -Fq 'TeamIdentifier=T34G959ZG8' <<<"$whisper_signature"

for binary in "$app/Contents/MacOS/$executable" "$whisper/Versions/A/whisper"; do
  test -f "$binary"
  architectures=$(lipo -archs "$binary")
  [[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] || {
    echo "Public release is not universal: $binary ($architectures)" >&2
    exit 1
  }
done

xcrun stapler validate "$app"
spctl --assess --type execute --verbose "$app"
printf 'Verified notarized AgentFlow %s build %s: %s\n' "$version" "$build" "$app"
