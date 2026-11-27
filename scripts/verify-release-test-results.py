#!/usr/bin/env python3
"""Require exact full-target coverage across fresh canonical Xcode test hosts."""
import argparse
import json
from pathlib import Path
import re


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def walk(nodes):
    for node in nodes:
        yield node
        yield from walk(node.get("children", []))


def results(path, log):
    data = json.loads(Path(path).read_text())
    cases = [node for node in walk(data["testNodes"]) if node.get("nodeType") == "Test Case"]
    names = [case.get("nodeIdentifier") for case in cases]
    require(cases and all(isinstance(name, str) and name for name in names),
            "Canonical action returned no complete named test results.")
    require(len(names) == len(set(names)), "Canonical action duplicated named test results.")
    require(all(case.get("result") == "Passed" for case in cases),
            "A canonical named test did not pass.")
    arguments = [node for case in cases for node in walk(case.get("children", []))
                 if node.get("nodeType") == "Arguments"]
    require(all(node.get("result") == "Passed" for node in arguments),
            "A parameterized argument did not pass.")
    summaries = re.findall(
        r"^[\s\u2063]*✔ Test run with ([1-9][0-9]*) tests in ([1-9][0-9]*) suites passed",
        Path(log).read_text(), re.MULTILINE)
    require(bool(summaries), "Canonical action lacks a nonzero passing test summary.")
    count, suites = map(int, summaries[-1])
    require(count == len(cases), "Swift summary does not match independent named Xcode results.")
    return {case["nodeIdentifier"]: case for case in cases}, suites


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("catalog", "native-suite", "native-results", "remaining-results",
                 "native-log", "remaining-log", "source", "build", "output"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    catalog = json.loads(Path(args.catalog).read_text())
    require(catalog.get("errors") == [], "Xcode discovery reported errors.")
    values = catalog.get("values", [])
    require(values and all(value.get("disabledTests") == [] for value in values),
            "Full release discovery contains disabled or missing tests.")
    target, separator, suite = args.native_suite.partition("/")
    require(separator and target and suite, "Invalid native-suite identifier.")
    prefix = target + "/"
    discovered = [test.get("identifier") for value in values
                  for test in value.get("enabledTests", [])]
    require(discovered and all(isinstance(name, str) and name.startswith(prefix)
                               for name in discovered), "Discovery contains missing or foreign identifiers.")
    names = [name[len(prefix):] for name in discovered]
    require(len(names) == len(set(names)) and len(names) >= 365,
            "Complete-target discovery is empty, duplicated or below the release coverage floor.")
    native_expected = {name for name in names if name.startswith(suite + "/")}
    remaining_expected = set(names) - native_expected
    require(native_expected and remaining_expected, "Both canonical partitions must execute tests.")
    native, native_suites = results(args.native_results, args.native_log)
    remaining, remaining_suites = results(args.remaining_results, args.remaining_log)
    require(set(native) == native_expected, "Native results do not exactly cover the discovered recorder suite.")
    require(set(remaining) == remaining_expected, "Remaining results do not exactly cover the discovered remainder.")
    require(not (set(native) & set(remaining)), "Canonical partitions overlap.")
    require(set(native) | set(remaining) == set(names), "Canonical partitions omit discovered tests.")

    # Preserve all four real layout/motion cases, beyond a function-level green.
    # This existing test is the regression that rejects the old invisible Mini card.
    # — GPT-6.1 Sol
    content_name = suite + "/finalSessionRetirementKeepsVisibleContentForTheCompletionFade(style:reducedMotion:)"
    require(content_name in native, "Real recorder-content regression did not execute.")
    arguments = [node for node in native[content_name].get("children", [])
                 if node.get("nodeType") == "Arguments"]
    require(len(arguments) == 4 and len({node.get("name") for node in arguments}) == 4,
            "All four distinct recorder layout/motion argument cases must execute.")

    require(re.fullmatch(r"[0-9a-f]{40}", args.source) is not None
            and re.fullmatch(r"[1-9][0-9]*", args.build) is not None,
            "Invalid exact source/build identity.")
    receipt = {
        "sourceCommit": args.source, "build": args.build,
        "discoveredFunctions": len(names), "namedFunctionsPassed": len(names),
        "suites": native_suites + remaining_suites,
        "nativeFunctionsPassed": len(native), "remainingFunctionsPassed": len(remaining),
        "nativeStyleMotionCasesPassed": len(arguments),
        "exactDisjointCoverage": True, "canonicalXcodeActionsPassed": 2,
        "tests": sorted(names),
    }
    Path(args.output).write_text(json.dumps(receipt, indent=2) + "\n")
    for name in sorted(names):
        print("Passed " + name)
    print("Full release suite passed: {} named tests, {} suites; source {}, build {}.".format(
        len(names), receipt["suites"], args.source, args.build))


if __name__ == "__main__":
    main()
