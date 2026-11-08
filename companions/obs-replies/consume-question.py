"""Read and atomically claim one OBS candidate for the exact open question.

This mechanical reader does not interpret speech, resolve/approve a question,
send a message, or start another agent. The waiting agent owns those decisions.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread-id", required=True)
    parser.add_argument("--question-id", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", args.thread_id, re.I) or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", args.question_id):
        raise ValueError("Require exact safe chat/question identifiers")
    root = Path.home() / ".codex/state/question-reminders" / args.thread_id
    offered = root / "reply-windows" / (args.question_id + ".json")
    claimed = offered.with_suffix(".consumed.json")
    if claimed.exists():
        print(json.dumps({"status": "already_consumed"}))
        return
    if not offered.exists():
        print(json.dumps({"status": "not_available"}))
        return
    # hard-link publication is an exclusive claim even if two readers race.
    try:
        os.link(offered, claimed)
    except FileExistsError:
        print(json.dumps({"status": "already_consumed"}))
        return
    except FileNotFoundError:
        print(json.dumps({"status": "not_available"}))
        return
    offered.unlink()
    candidate = json.loads(claimed.read_text())
    request = candidate.get("request", {})
    try:
        ledger = json.loads((root / "pending-questions.json").read_text())
    except (OSError, ValueError):
        ledger = {}
    if (request.get("threadID") != args.thread_id or request.get("questionID") != args.question_id or
        ledger.get("thread_id") != args.thread_id or
        not any(q.get("question_id") == args.question_id and q.get("status") == "open" for q in ledger.get("questions", []))):
        print(json.dumps({"status": "superseded"}))
        return
    print(json.dumps({"status": "untrusted_candidate", "candidate": candidate}, ensure_ascii=False))


if __name__ == "__main__":
    main()
