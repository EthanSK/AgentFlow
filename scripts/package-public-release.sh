#!/usr/bin/env bash
set -euo pipefail

# Run only from a clean, exact release checkout on the dedicated Mac Mini.
# Keep output outside the source tree. Never overwrite the installed app or a published release.
root=$(cd "$(dirname "$0")/.." && pwd)
output=${1:?Pass a fresh, task-scoped output directory}
: "${VOICEINK_NOTARY_PROFILE:?Set a validated notarytool Keychain profile}"
identity=${VOICEINK_DEVELOPER_ID:-Developer ID Application: Ethan Sarif-Kattan (T34G959ZG8)}
whisper_commit=0ec0845110dc934911dc48e8c5beb5ad3189b3f3
whisper_repo="$HOME/VoiceInk-Dependencies/whisper.cpp"
whisper_framework="$whisper_repo/build-apple/whisper.xcframework"

test "$(hostname)" = Ethans-Mac-mini-6.local || {
  echo 'Public AgentFlow builds must run on the dedicated Mac Mini.' >&2
  exit 1
}
test ! -e "$output" || { echo 'Use a fresh output directory.' >&2; exit 1; }
test -z "$(git -C "$root" status --porcelain)" || {
  echo 'Release checkout is dirty; commit the exact source first.' >&2
  exit 1
}
test "$(wc -l <"$root/LICENSE" | tr -d ' ')" -ge 600
grep -Fq 'END OF TERMS AND CONDITIONS' "$root/LICENSE"
source_build=$(grep 'CURRENT_PROJECT_VERSION = ' "$root/VoiceInk.xcodeproj/project.pbxproj" | head -1 | sed -E 's/.*= ([0-9]+);/\1/')
test "$source_build" -gt 343 || {
  echo 'Increment the native build beyond the last installed VoiceInk++ build 343 before public distribution.' >&2
  exit 1
}
source_version=$(grep 'MARKETING_VERSION = ' "$root/VoiceInk.xcodeproj/project.pbxproj" | head -1 | sed -E 's/.*= ([0-9.]+);/\1/')
[[ "$source_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
tag_result=0
git -C "$root" ls-remote --exit-code --tags origin "refs/tags/v${source_version}.${source_build}" >/dev/null || tag_result=$?
case "$tag_result" in
  0) echo 'This version/build tag already exists; refusing to reuse it.' >&2; exit 1 ;;
  2) ;;
  *) echo 'Could not check remote release tags; refusing an uncertain build.' >&2; exit 1 ;;
esac
test "$(git -C "$whisper_repo" rev-parse HEAD)" = "$whisper_commit"
test -d "$whisper_framework"
security find-identity -v -p codesigning | grep -Fq "\"$identity\"" || {
  echo 'Developer ID signing identity is unavailable.' >&2
  exit 1
}
xcrun notarytool history --keychain-profile "$VOICEINK_NOTARY_PROFILE" --output-format json >/dev/null || {
  echo 'Notary credentials are unavailable; refusing an unnotarized public build.' >&2
  exit 1
}

mkdir -p "$output"
"$root/scripts/test-public-release.sh" "$output"
# Keep the named test logs, then reclaim only this release's generated test host before building
# a separate universal Release app. The Mini can run out of space when both DerivedData trees coexist.
test -d "$output/TestDerivedData"
rm -rf "$output/TestDerivedData" "$output/TestFrameworks"

build_log="$output/xcode-release-build.log"
derived="$output/ReleaseDerivedData"
xcodebuild -project "$root/VoiceInk.xcodeproj" -scheme VoiceInk \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" -xcconfig "$root/LocalBuild.xcconfig" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= "CODE_SIGN_ENTITLEMENTS=$root/VoiceInk/VoiceInk.local.entitlements" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD' \
  ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' build >"$build_log" 2>&1 || {
    tail -50 "$build_log" >&2
    exit 1
  }

built="$derived/Build/Products/Release/AgentFlow.app"
app="$output/AgentFlow.app"
test -d "$built"
if find "$built/Contents" \( -name '*.xctest' -o -name '*XCTest*' \) -print -quit | grep -q .; then
  echo 'Refusing to package an Xcode test host.' >&2
  exit 1
fi
ditto "$built" "$app"
ditto "$root/LICENSE" "$app/Contents/Resources/COPYING"

# Sign nested code inside-out before the outer bundle. A generic outer-only re-sign both breaks
# library validation and silently removes Automation unless the checked-in entitlements return.
sparkle_autoupdate="$app/Contents/Frameworks/Sparkle.framework/Versions/A/Autoupdate"
if test -f "$sparkle_autoupdate"; then
  codesign --force --options runtime --timestamp --sign "$identity" "$sparkle_autoupdate"
fi
find "$app/Contents" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \
  -o -name '*.app' -o -name '*.dylib' \) -print |
while IFS= read -r item; do
  codesign --force --options runtime --timestamp --sign "$identity" "$item"
done
codesign --force --options runtime --timestamp --sign "$identity" \
  --entitlements "$root/VoiceInk/VoiceInk.local.entitlements" "$app"
codesign --verify --deep --strict "$app"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
archive="$output/AgentFlow-v${version}.${build}-mac-universal.zip"
submission="$output/notary-submission.zip"
ditto -c -k --keepParent "$app" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$VOICEINK_NOTARY_PROFILE" \
  --wait --timeout 45m --output-format json >"$output/notary-result.json"
/usr/bin/python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); assert data.get("status")=="Accepted", data.get("status")' \
  "$output/notary-result.json"
xcrun stapler staple "$app"
"$root/scripts/verify-public-release.sh" "$app"
ditto -c -k --keepParent "$app" "$archive"

archive_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
cdhash=$(codesign -d --verbose=4 "$app" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
source_sha=$(git -C "$root" rev-parse HEAD)
ARCHIVE="$archive" ARCHIVE_SHA="$archive_sha" CDHASH="$cdhash" SOURCE_SHA="$source_sha" \
  VERSION="$version" BUILD="$build" /usr/bin/python3 -c '
import json, os, pathlib
out = pathlib.Path(os.environ["ARCHIVE"]).with_name("release.json")
out.write_text(json.dumps({"version": os.environ["VERSION"], "build": os.environ["BUILD"],
  "sourceCommit": os.environ["SOURCE_SHA"], "archive": pathlib.Path(os.environ["ARCHIVE"]).name,
  "sha256": os.environ["ARCHIVE_SHA"], "cdhash": os.environ["CDHASH"],
  "architectures": ["arm64", "x86_64"], "developerIdTeam": "T34G959ZG8",
  "notarized": True}, indent=2) + "\n")'
shasum -a 256 "$archive" >"$output/SHA256SUMS"
printf 'Notarized release ready: %s\nSource: %s\nSHA-256: %s\n' "$archive" "$source_sha" "$archive_sha"
