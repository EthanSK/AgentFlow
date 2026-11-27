#!/usr/bin/env bash
set -euo pipefail

# Qualify the complete discovered target from one exact source/build. The native
# recorder suite gets a fresh canonical test host before other AppKit fixtures.
# Hosted observations measured up to518ms between samples of a220ms fade; keep
# every strict frame/content guard instead of lengthening the user's animation.
# — GPT-6.1 Sol
root=$(cd "$(dirname "$0")/.." && pwd)
output=${1:?Pass a fresh, task-scoped output directory}
mkdir -p "$output"
export LLVM_PROFILE_FILE="$output/profile-%p.profraw"
test -z "$(git -C "$root" status --porcelain)"

project="$root/VoiceInk.xcodeproj/project.pbxproj"
builds=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);/\1/p' "$project" | sort -u)
test "$(printf '%s\n' "$builds" | wc -l | tr -d ' ')" = 2 || {
  echo 'Unexpected Xcode build-version settings; inspect the project before release.' >&2
  exit 1
}
app_build=$(grep 'CURRENT_PROJECT_VERSION = ' "$project" | head -1 | sed -E 's/.*= ([0-9]+);/\1/')
[[ "$app_build" =~ ^[1-9][0-9]*$ ]]
test "$(grep -Fc "CURRENT_PROJECT_VERSION = $app_build;" "$project")" -ge 2

derived="$output/TestDerivedData.noindex"
native_suite=VoiceInkTests/RecorderPanelDismissalTests
common=(
  -project "$root/VoiceInk.xcodeproj" -scheme VoiceInk -configuration Debug
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived"
  -clonedSourcePackagesDirPath "${AGENTFLOW_PACKAGES_DIR:-$output/Packages.noindex}"
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates
  -parallel-testing-enabled NO -jobs 2 -xcconfig "$root/LocalBuild.xcconfig"
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
  DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO
  "CODE_SIGN_ENTITLEMENTS=$root/VoiceInk/VoiceInk.local.entitlements"
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD'
)

canonical_action() {
  local log=$1
  shift
  local result=0
  /usr/bin/python3 -c 'import subprocess,sys; subprocess.run(sys.argv[1:], timeout=900, check=True)' \
    xcodebuild "${common[@]}" "$@" >"$log" 2>&1 || result=$?
  # A green Swift summary never overrules Xcode/XCTest failure. Neither action
  # may fall back to an unfiltered direct runner: that would lose this partition.
  # TestManager stalls remain failures with evidence, never zero-test passes.
  if (( result != 0 )); then
    echo "Xcode failed (exit $result): $log" >&2
    grep -E '✘|Expectation failed|[Ii]ssue recorded|RecorderFadeDiagnostic|error:' "$log" >&2 || true
    tail -35 "$log" >&2
    exit 1
  fi
  if ! grep -Eq '✔ Test run with [1-9][0-9]* tests in [1-9][0-9]* suites passed' "$log"; then
    echo "Canonical action has no nonzero passing Swift Testing summary: $log" >&2
    tail -35 "$log" >&2
    exit 1
  fi
}

canonical_action "$output/xcode-recorder-tests.log" \
  "-only-testing:$native_suite" -resultBundlePath "$output/RecorderPanelTests.xcresult" test

# Ask Xcode for the complete target independently of either selection. This is
# discovery, not execution; the verifier requires exact, disjoint result coverage.
# Build once above; subsequent commands use those same test products.
catalog="$output/test-catalog.json"
/usr/bin/python3 -c 'import subprocess,sys; subprocess.run(sys.argv[1:], timeout=180, check=True)' \
  xcodebuild "${common[@]}" -only-testing:VoiceInkTests -enumerate-tests \
  -test-enumeration-style flat -test-enumeration-format json \
  -test-enumeration-output-path "$catalog" test-without-building \
  >"$output/xcode-test-discovery.log" 2>&1

canonical_action "$output/xcode-remaining-tests.log" \
  -only-testing:VoiceInkTests "-skip-testing:$native_suite" \
  -resultBundlePath "$output/RemainingTests.xcresult" test-without-building

xcrun xcresulttool get test-results tests --path "$output/RecorderPanelTests.xcresult" \
  --compact >"$output/native-test-results.json"
xcrun xcresulttool get test-results tests --path "$output/RemainingTests.xcresult" \
  --compact >"$output/remaining-test-results.json"

# The single validator owns full named coverage/accounting for both real actions.
# No test is skipped merely because its UI timing needs a fresh process.
python3 "$root/scripts/verify-release-test-results.py" \
  --catalog "$catalog" --native-suite "$native_suite" \
  --native-results "$output/native-test-results.json" \
  --remaining-results "$output/remaining-test-results.json" \
  --native-log "$output/xcode-recorder-tests.log" \
  --remaining-log "$output/xcode-remaining-tests.log" \
  --source "$(git -C "$root" rev-parse HEAD)" --build "$app_build" \
  --output "$output/qualified-tests.json"
