#!/usr/bin/env python3
"""Exercise the production Sparkle signing block without a certificate or native build."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = (ROOT / "scripts/package-public-release.sh").read_text()
START = PACKAGE.index('sparkle_autoupdate="$app/Contents/Frameworks/Sparkle.framework/')
END = PACKAGE.index('\nfind "$app/Contents" -depth', START)
BLOCK = PACKAGE[START:END]


class SparkleSigningTests(unittest.TestCase):
    def test_entitlements_read_signed_types_instead_of_pretty_printed_booleans(self):
        import plistlib
        source = (ROOT / "scripts/verify-public-release.sh").read_text()
        start = source.index("entitlements=")
        block = source[start:source.index('\ntest "$(wc', start)]
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "entitlements.plist"
            for automation, microphone in ((True, True), (False, True), (True, False), ("true", True), (1, True)):
                with self.subTest(automation=automation, microphone=microphone):
                    fixture.write_bytes(plistlib.dumps({
                        "com.apple.security.automation.apple-events": automation,
                        "com.apple.security.device.audio-input": microphone,
                    }))
                    # Execute the real gate with signed-plist bytes. The legacy formatter
                    # reproduces macOS 15's numeric display and must not define truth.
                    script = ('set -eu\napp=fixture.app\n'
                              'codesign() { cat "$FIXTURE_ENTITLEMENTS"; }\n'
                              'plutil() { cat >/dev/null; printf \'"com.apple.security.automation.apple-events" => 1\\n"com.apple.security.device.audio-input" => 1\\n\'; }\n'
                              + block)
                    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                                            env={**os.environ, "FIXTURE_ENTITLEMENTS": str(fixture)})
                    expected = automation is True and microphone is True
                    self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_default_app_configs_match_standalone_signature(self):
        import json
        import plistlib
        project = ROOT / "VoiceInk.xcodeproj/project.pbxproj"
        data = json.loads(subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", str(project)]))["objects"]
        app, = (obj for obj in data.values()
                if obj.get("productType") == "com.apple.product-type.application")
        configs = [data[key] for key in data[app["buildConfigurationList"]]["buildConfigurations"]]
        self.assertEqual({cfg["name"] for cfg in configs}, {"Release", "Debug"})
        for config in configs:
            with self.subTest(configuration=config["name"]):
                settings = config["buildSettings"]
                self.assertIn("LOCAL_BUILD", settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].split())
                entitlements = plistlib.loads((ROOT / settings["CODE_SIGN_ENTITLEMENTS"]).read_bytes())
                self.assertTrue(entitlements["com.apple.security.device.audio-input"])
                self.assertNotIn("com.apple.developer.icloud-container-identifiers", entitlements)

    def release_gate_fixture(self, xcode_exit=0, fault="", parameter_prefix=""):
        import copy
        import json
        import shutil
        import textwrap
        native_names = [
            "completionFadeDoesNotWaitOrHideANewerPresentation()",
            "fadingKeepsNextOwnedAndPrimaryCanStartWithoutWaiting()",
            "nativeCancelPreemptsAnObservedFadeWithoutHidingEitherLayout()",
            "nativeFadeInterpolatesBothLayoutsAndReleasesEveryMirror()",
            "reservedStartsCancelTheOldFadeBeforeYieldingOrOpeningAudio()",
            "resetAndReducedMotionHideImmediatelyAndPreserveMouseState()",
            "finalSessionRetirementKeepsVisibleContentForTheCompletionFade(style:reducedMotion:)",
        ]
        native = [{"nodeType": "Test Case", "nodeIdentifier": "RecorderPanelDismissalTests/" + name,
                   "result": "Passed"} for name in native_names]
        native[-1]["children"] = [{"nodeType": "Arguments", "name": name, "result": "Passed"}
                                  for name in (".mini, false", ".mini, true", ".notch, false", ".notch, true")]
        remaining = [{"nodeType": "Test Case", "nodeIdentifier": f"Fixture/fixture{i}()",
                      "result": "Passed"} for i in range(358)]
        catalog = {"errors": [], "values": [{"testPlan": "VoiceInk", "disabledTests": [],
                    "enabledTests": [{"identifier": "VoiceInkTests/" + node["nodeIdentifier"]}
                                     for node in native + remaining]}]}
        if fault == "missing":
            remaining.pop()
        elif fault == "overlap":
            remaining.append(copy.deepcopy(native[0]))
        elif fault == "failed_case":
            remaining[0]["result"] = "Failed"
        elif fault == "skipped_argument":
            native[-1]["children"][0]["result"] = "Skipped"
        elif fault == "missing_argument":
            native[-1]["children"].pop()
        elif fault == "duplicate":
            remaining.append(copy.deepcopy(remaining[0]))
        elif fault == "discovery_error":
            catalog["errors"] = ["Synthetic discovery failure"]
        elif fault == "disabled":
            catalog["values"][0]["disabledTests"] = [{"identifier": "VoiceInkTests/Fixture/disabled()"}]
        elif fault == "foreign":
            catalog["values"][0]["enabledTests"][0]["identifier"] = "OtherTarget/Fixture/foreign()"
        elif fault == "duplicate_catalog":
            catalog["values"][0]["enabledTests"].append(copy.deepcopy(catalog["values"][0]["enabledTests"][0]))
        elif fault == "zero_native":
            native.clear()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repo = base / "repo"
            (repo / "scripts").mkdir(parents=True)
            (repo / "VoiceInk.xcodeproj").mkdir()
            for name in ("test-public-release.sh", "verify-release-test-results.py"):
                shutil.copy2(ROOT / "scripts" / name, repo / "scripts" / name)
            shutil.copy2(ROOT / "VoiceInk.xcodeproj/project.pbxproj",
                         repo / "VoiceInk.xcodeproj/project.pbxproj")
            fixture = base / "fixture.json"
            fixture.write_text(json.dumps({"native": native, "remaining": remaining, "catalog": catalog}))
            fake = repo / "xcodebuild"
            fake.write_text("#!/usr/bin/env python3\n" + textwrap.dedent("""
                import json,os,sys
                from pathlib import Path
                args=sys.argv[1:]
                data=json.loads(Path(os.environ["FIXTURE_DATA"]).read_text())
                if "-enumerate-tests" in args:
                    assert "-only-testing:VoiceInkTests" in args and "test-without-building" in args
                    Path(args[args.index("-test-enumeration-output-path")+1]).write_text(json.dumps(data["catalog"]))
                    print("Discovery only")
                    sys.exit(0)
                native="-only-testing:VoiceInkTests/RecorderPanelDismissalTests" in args
                if native:
                    assert "test" in args
                else:
                    assert "-skip-testing:VoiceInkTests/RecorderPanelDismissalTests" in args
                    assert "-only-testing:VoiceInkTests" in args and "test-without-building" in args
                with Path(os.environ["FIXTURE_CALLS"]).open("a") as calls:
                    calls.write(("native" if native else "remaining") + "\\n")
                cases=data["native" if native else "remaining"]
                for case in cases:
                    if case.get("children"):
                        print(os.environ["FIXTURE_PARAMETER_PREFIX"]+"✔ Test parameter() with 4 test cases passed after 0.01 seconds.")
                    else:
                        print("✔ Test fixture() passed after 0.01 seconds.")
                count=len(cases)+(1 if os.environ["FIXTURE_FAULT"]=="summary_count" and not native else 0)
                print(f"✔ Test run with {count} tests in 1 suites passed after 0.02 seconds.")
                sys.exit(int(os.environ["FIXTURE_XCODE_EXIT"]))
            """))
            fake.chmod(0o755)
            fake_result = repo / "xcrun"
            fake_result.write_text("#!/usr/bin/env python3\n" + textwrap.dedent("""
                import json,os,sys
                from pathlib import Path
                args=sys.argv[1:]
                path=args[args.index("--path")+1]
                data=json.loads(Path(os.environ["FIXTURE_DATA"]).read_text())
                cases=data["native" if path.endswith("/RecorderPanelTests.xcresult") else "remaining"]
                print(json.dumps({"testNodes":cases}))
            """))
            fake_result.chmod(0o755)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture",
                            "-c", "user.email=fixture@localhost", "commit", "-qm", "Fixture"], check=True)
            calls = base / "calls.txt"
            result = subprocess.run(
                ["bash", str(repo / "scripts/test-public-release.sh"), str(base / "output")],
                env={**os.environ, "PATH": str(repo) + ":" + os.environ["PATH"],
                     "FIXTURE_DATA": str(fixture), "FIXTURE_CALLS": str(calls),
                     "FIXTURE_XCODE_EXIT": str(xcode_exit), "FIXTURE_FAULT": fault,
                     "FIXTURE_PARAMETER_PREFIX": parameter_prefix}, capture_output=True, text=True)
            executed = calls.read_text().splitlines() if calls.exists() else []
            receipt = base / "output/qualified-tests.json"
            return result, executed, json.loads(receipt.read_text()) if receipt.exists() else None

    def test_failed_xcode_run_cannot_pass_with_green_swift_testing_summary(self):
        for xcode_exit, prefix in ((0, ""), (0, "\u2063"), (65, ""), (65, "\u2063")):
            with self.subTest(xcode_exit=xcode_exit, parameter_prefix=prefix):
                result, calls, receipt = self.release_gate_fixture(xcode_exit=xcode_exit, parameter_prefix=prefix)
                self.assertEqual(result.returncode == 0, xcode_exit == 0, result.stderr)
                if xcode_exit:
                    self.assertIn("Xcode failed", result.stderr)
                    self.assertEqual(calls, ["native"])
                    self.assertIsNone(receipt)
                else:
                    self.assertEqual(calls, ["native", "remaining"])
                    self.assertEqual(receipt["namedFunctionsPassed"], 365)
                    self.assertTrue(receipt["exactDisjointCoverage"])
                    self.assertEqual(receipt["nativeStyleMotionCasesPassed"], 4)

    def test_full_release_rejects_incomplete_or_false_green_partition_receipts(self):
        for fault in ("missing", "overlap", "failed_case", "skipped_argument",
                      "missing_argument", "duplicate", "discovery_error", "disabled",
                      "foreign", "duplicate_catalog", "zero_native", "summary_count"):
            with self.subTest(fault=fault):
                result, _, receipt = self.release_gate_fixture(fault=fault)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIsNone(receipt)

    def test_public_checksum_manifest_works_in_another_download_folder(self):
        line = next(line for line in PACKAGE.splitlines()
                    if line.startswith('(cd "$output" && shasum'))
        with tempfile.TemporaryDirectory(prefix="release builder ") as build, \
                tempfile.TemporaryDirectory(prefix="user download ") as download:
            archive = Path(build) / "AgentFlow-v2.0.458-mac-universal.zip"
            archive.write_bytes(b"fixture archive")
            appcast = Path(build) / "appcast.xml"
            appcast.write_bytes(b"fixture signed feed")
            subprocess.run(["bash", "-ec", line], check=True,
                           env={**os.environ, "output": build, "archive": str(archive)})
            import shutil
            shutil.copy2(archive, download)
            shutil.copy2(appcast, download)
            shutil.copy2(Path(build) / "SHA256SUMS", download)
            result = subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"],
                                    cwd=download, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(build, (Path(download) / "SHA256SUMS").read_text())

    def test_coverage_output_stays_outside_source_checkout(self):
        source = (ROOT / "scripts/test-public-release.sh").read_text()
        lines = [line for line in source.splitlines()
                 if line.startswith("export LLVM_PROFILE_FILE=")]
        self.assertEqual(len(lines), 1)
        with tempfile.TemporaryDirectory(prefix="agentflow release coverage ") as output:
            result = subprocess.run(
                ["bash", "-c", 'set -eu; output="$1"; ' + lines[0]
                 + '; printf "%s" "$LLVM_PROFILE_FILE"', "fixture", output],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, str(Path(output) / "profile-%p.profraw"))

    def run_fixture(self, version, helper=True):
        with tempfile.TemporaryDirectory(prefix="agentflow-signing-test-") as directory:
            base = Path(directory)
            app = base / "AgentFlow.app"
            versions = app / "Contents/Frameworks/Sparkle.framework/Versions"
            (versions / version).mkdir(parents=True)
            (versions / "Current").symlink_to(version)
            if helper:
                (versions / version / "Autoupdate").touch()
            receipt = base / "signing-receipt"
            # Stub only the irreversible operation; execute the actual path/guard logic.
            script = ('set -eu\nidentity="Fixture identity"\n'
                      'codesign() { printf "%s\\n" "$*" >> "$receipt"; }\n' + BLOCK)
            result = subprocess.run(
                ["bash", "-c", script], capture_output=True, text=True,
                env={**os.environ, "app": str(app), "receipt": str(receipt)})
            calls = receipt.read_text() if receipt.exists() else ""
            return result, calls

    def test_version_a_is_signed_with_runtime_and_timestamp(self):
        result, calls = self.run_fixture("A")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--options runtime --timestamp", calls)
        self.assertIn("Versions/Current/Autoupdate", calls)

    def test_version_b_is_not_silently_skipped(self):
        result, calls = self.run_fixture("B")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls.splitlines()), 1)
        self.assertIn("Versions/Current/Autoupdate", calls)

    def test_missing_helper_fails_before_signing(self):
        result, calls = self.run_fixture("B", helper=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Sparkle Autoupdate helper is missing", result.stderr)
        self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
