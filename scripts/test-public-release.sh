#!/usr/bin/env bash
set -euo pipefail

# A public binary needs a full, named test pass from its exact source/build.
# Run on the dedicated Mac Mini, in a clean checkout; do not copy the test host into a release.
root=$(cd "$(dirname "$0")/.." && pwd)
output=${1:?Pass a fresh, task-scoped output directory}
mkdir -p "$output"
test "$(git -C "$root" status --porcelain | wc -l | tr -d ' ')" = 0

project="$root/VoiceInk.xcodeproj/project.pbxproj"
builds=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);/\1/p' "$project" | sort -u)
test "$(printf '%s\n' "$builds" | wc -l | tr -d ' ')" = 2 || {
  # App and test target each carry a build value; require the app's two configurations to agree.
  echo 'Unexpected Xcode build-version settings; inspect the project before release.' >&2
  exit 1
}
app_build=$(grep 'CURRENT_PROJECT_VERSION = ' "$project" | head -1 | sed -E 's/.*= ([0-9]+);/\1/')
[[ "$app_build" =~ ^[1-9][0-9]*$ ]]
test "$(grep -Fc "CURRENT_PROJECT_VERSION = $app_build;" "$project")" -ge 2

derived="$output/TestDerivedData"
canonical_log="$output/xcode-full-tests.log"
canonical_result=0
/usr/bin/python3 -c 'import subprocess,sys; subprocess.run(sys.argv[1:], timeout=900, check=True)' \
  xcodebuild -project "$root/VoiceInk.xcodeproj" -scheme VoiceInk \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$derived" -resultBundlePath "$output/FullTests.xcresult" \
  -xcconfig "$root/LocalBuild.xcconfig" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= "CODE_SIGN_ENTITLEMENTS=$root/VoiceInk/VoiceInk.local.entitlements" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD' \
  test >"$canonical_log" 2>&1 || canonical_result=$?

passed_log="$canonical_log"
if ! grep -Eq '^✔ Test run with [1-9][0-9]* tests in [1-9][0-9]* suites passed' "$canonical_log"; then
  # TestManager has repeatedly stalled at zero named tests on this Mini. The direct runner is
  # allowed only for this full-suite release gate, against the already-built bundle.
  if grep -Eq '^[◇✔✘] Test .+\(' "$canonical_log"; then
    echo 'Canonical Xcode runner executed tests but did not pass; refusing fallback.' >&2
    tail -35 "$canonical_log" >&2
    exit 1
  fi
  host="$derived/Build/Products/Debug/AgentFlow.app"
  bundle="$host/Contents/PlugIns/VoiceInkTests.xctest"
  test -d "$bundle" || { echo 'Xcode did not build the test bundle.' >&2; exit 1; }
  # The direct runner uses a different Bundle.main. Keep the built host untouched and stage its
  # package resource beside a disposable framework copy so MediaRemoteAdapter can find it.
  resource_bundle="$host/Contents/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle"
  test -d "$resource_bundle" || { echo 'MediaRemoteAdapter test resource is missing.' >&2; exit 1; }
  staged_frameworks="$output/TestFrameworks"
  ditto "$host/Contents/Frameworks" "$staged_frameworks"
  ditto "$resource_bundle" \
    "$staged_frameworks/MediaRemoteAdapter.framework/Versions/A/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle"
  passed_log="$output/direct-full-tests.log"
  DYLD_LIBRARY_PATH="$host/Contents/MacOS" \
  DYLD_FRAMEWORK_PATH="$staged_frameworks:$host/Contents/Frameworks:$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
    /usr/bin/python3 -c 'import subprocess,sys; subprocess.run(sys.argv[1:], timeout=600, check=True)' \
    xcrun xctest "$bundle" >"$passed_log" 2>&1 || {
      echo "Full-suite fallback failed (canonical exit $canonical_result)." >&2
      tail -35 "$passed_log" >&2
      exit 1
    }
fi

summary=$(grep -E '^✔ Test run with [1-9][0-9]* tests in [1-9][0-9]* suites passed' "$passed_log" | tail -1)
[[ "$summary" =~ ^✔\ Test\ run\ with\ ([0-9]+)\ tests\ in\ ([0-9]+)\ suites\ passed ]] || {
  echo 'No passing Swift Testing suite summary.' >&2
  exit 1
}
count=${BASH_REMATCH[1]}
named=$(grep -E '^✔ Test .* passed after' "$passed_log" | grep -v '^✔ Test run' | wc -l | tr -d ' ')
test "$count" -ge 362
test "$named" = "$count" || {
  echo "Test summary names $count tests but output contains $named named passes." >&2
  exit 1
}
printf 'Full release suite passed: %s named tests, %s suites; source %s, build %s.\n' \
  "$count" "${BASH_REMATCH[2]}" "$(git -C "$root" rev-parse HEAD)" "$app_build"
