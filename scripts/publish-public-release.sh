#!/usr/bin/env bash
set -euo pipefail

# Publish only the Mini-built artifact after signing/notarization. Publication never rebuilds it.
root=$(cd "$(dirname "$0")/.." && pwd)
release_dir=${1:?Pass the directory containing release.json and the notarized ZIP}
manifest="$release_dir/release.json"
test -f "$manifest"
test -f "$release_dir/SHA256SUMS"
command -v gh >/dev/null

IFS=$'\t' read -r version build source_sha archive_name expected_sha < <(/usr/bin/python3 -c '
import json, pathlib, sys
d=json.load(open(sys.argv[1]))
assert d["notarized"] is True
assert d["developerIdTeam"] == "T34G959ZG8"
assert d["architectures"] == ["arm64", "x86_64"]
print("\t".join(str(d[key]) for key in ("version", "build", "sourceCommit", "archive", "sha256")))
' "$manifest")
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
[[ "$build" =~ ^[1-9][0-9]*$ && "$source_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$archive_name" == "AgentFlow-v${version}.${build}-mac-universal.zip" ]]
archive="$release_dir/$archive_name"
test -f "$archive"
actual_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
test "$actual_sha" = "$expected_sha"
(cd "$release_dir" && shasum -a 256 -c SHA256SUMS)

inspect=$(mktemp -d "${TMPDIR:-/private/tmp}/voiceink-public-inspect.XXXXXX")
trap 'rm -rf "$inspect"' EXIT
ditto -xk "$archive" "$inspect"
"$root/scripts/verify-public-release.sh" "$inspect/AgentFlow.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$inspect/AgentFlow.app/Contents/Info.plist")" = "$build"

repo=EthanSK/AgentFlow
tag="v${version}.${build}"
test "$(gh api "repos/$repo/commits/$source_sha" --jq .sha)" = "$source_sha"
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  echo "Release $tag already exists. Refusing to overwrite its assets." >&2
  exit 1
fi
notes="Developer ID-signed and Apple-notarized Agent Flow for Apple silicon and Intel, macOS 14.4 or later.

Download the ZIP, extract AgentFlow.app, and move it to Applications. Give the app Microphone and Accessibility access, then add your OpenAI API key for GPT Live. The YouTube Bridge, Chrome extension, context skill, and Agentic Mouse are separate optional setup steps.

This is a public download, not an automatic in-app update. Before replacing an existing Agent Flow or VoiceInk++ install, stop any recording and keep a backup of the old app. The official VoiceInk app is a separate product.

Setup: https://github.com/$repo/blob/$source_sha/SETUP.md
Corresponding GPLv3 source: https://github.com/$repo/tree/$source_sha
SHA-256: $expected_sha"
gh release create "$tag" --repo "$repo" --target "$source_sha" --draft \
  --title "Agent Flow $tag" --notes "$notes" \
  "$archive" "$release_dir/SHA256SUMS" "$manifest"
assets=$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')
for name in "$archive_name" SHA256SUMS release.json; do
  grep -Fxq "$name" <<<"$assets"
done
gh release edit "$tag" --repo "$repo" --draft=false --latest
printf 'Published verified Agent Flow release: https://github.com/%s/releases/tag/%s\n' "$repo" "$tag"
