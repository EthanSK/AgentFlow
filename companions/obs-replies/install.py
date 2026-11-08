"""Review/install the optional OBS reply hook without restarting any application.

Dry-run is the default. --apply backs up exact shared TTS sources, patches only
known anchors and installs a reproducible companion copy. It never changes OBS,
Agent Flow's native app/preferences, microphones, permissions or login services.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import os
import sys
import time
import uuid
from skill_guidance import compose_skill

ROOT = Path(__file__).resolve().parent
BEGIN = "# BEGIN optional Agent Flow OBS replies"
END = "# END optional Agent Flow OBS replies"


def atomic_text(path: Path, text: str, mode: int = 0o600) -> None:
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "w") as file:
        file.write(text)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)


def replace_once(source: str, anchor: str, replacement: str) -> str:
    if source.count(anchor) != 1:
        raise ValueError("Shared speech source differs from the supported integration; preserve it and review")
    return source.replace(anchor, replacement, 1)


def integrated_sources(speech_root: Path) -> dict[Path, str]:
    queue = speech_root / "speech_queue.py"
    speaker = speech_root / "speak-with-youtube.swift"
    completion = speech_root / "completion-speech-worker.py"
    result = {}
    # Updates to shared speech code need a fresh integration review. A marker
    # alone cannot prove that an older installed hook matches this source.
    existing = [queue, speaker, completion, speech_root.parents[1] / "question-reminders/scripts/remind-now.py"]
    if any(BEGIN in path.read_text() or "// BEGIN optional Agent Flow OBS replies" in path.read_text() for path in existing):
        raise ValueError("OBS speech integration already exists; review its backup and migrate explicitly instead of retaining an unknown hook")
    source = queue.read_text()
    if BEGIN not in source:
        source = replace_once(source, "from codex_voice_gate import VoiceGate\n",
            "from codex_voice_gate import VoiceGate\n" + BEGIN + "\n"
            "from obs_reply_hook import begin as begin_obs_reply, finish as finish_obs_reply\n" + END + "\n")
        source = replace_once(source, "    process = None\n    with tempfile.TemporaryFile() as errors:\n",
            "    process = None\n    actual_environment = dict(os.environ if env is None else env)\n"
            "    obs_reply = begin_obs_reply(command, actual_environment)\n"
            "    if obs_reply is not None:\n"
            "        actual_environment['AGENTFLOW_OBS_PLAYBACK_RECEIPT'] = str(obs_reply['event'] / 'playback-end.json')\n"
            "        actual_environment['AGENTFLOW_OBS_EVENT_ID'] = obs_reply['event_id']\n"
            "        actual_environment['AGENTFLOW_OBS_LATEST_FILE'] = str(obs_reply['latest_file'])\n"
            "    with tempfile.TemporaryFile() as errors:\n")
        source = replace_once(source, "process = subprocess.Popen(command, env=env, stdin=ticket_fd,",
            "process = subprocess.Popen(command, env=actual_environment, stdin=ticket_fd,")
        source = replace_once(source, "            return {'outcome': outcome or ('spoken' if process.returncode == 0 else 'failed'),",
            "            receipt = {'outcome': outcome or ('spoken' if process.returncode == 0 else 'failed'),")
        source = replace_once(source, "                    'details': [line.strip() for line in details if line.strip()][-3:]}\n        finally:\n",
            "                    'details': [line.strip() for line in details if line.strip()][-3:]}\n"
            "            finish_obs_reply(obs_reply, receipt)\n            obs_reply = None\n            return receipt\n        finally:\n"
            "            if obs_reply is not None:\n                finish_obs_reply(obs_reply, {'outcome': 'failed'})\n")
    result[queue] = source
    source = speaker.read_text()
    swift_begin = "// BEGIN optional Agent Flow OBS replies"
    if swift_begin not in source:
        source = replace_once(source, "let speech = Process()\n", "let speech = Process()\n" + swift_begin + "\n" +
            (ROOT / "playback-observation.swift").read_text() + "// END optional Agent Flow OBS replies\n")
        source = replace_once(source, "            overlapLease.audioStarted(pid: speech.processIdentifier)\n",
            "            overlapLease.audioStarted(pid: speech.processIdentifier)\n            publishOBSReplyPlaybackStart()\n")
        source = replace_once(source, "let suppliedBudget = args.count == 5",
            'if let receiptPath = ProcessInfo.processInfo.environment["AGENTFLOW_OBS_PLAYBACK_RECEIPT"] {\n'
            '    let reference = URL(fileURLWithPath: receiptPath).deletingLastPathComponent().appendingPathComponent("playback-reference.audio")\n'
            '    try? FileManager.default.copyItem(at: playbackAudio, to: reference)\n'
            '    _ = chmod(reference.path, S_IRUSR | S_IWUSR)\n}\n\nlet suppliedBudget = args.count == 5')
    result[speaker] = source
    source = completion.read_text()
    if BEGIN not in source:
        source = replace_once(source, "import json\n", "import json\nimport os\nimport re\n")
        source = replace_once(source, "def finish(home, sentence, audio, payload):\n",
            "def finish(home, sentence, audio, payload):\n    " + BEGIN + "\n"
            "    origin = payload.get('session_id', '')\n"
            "    if re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', origin, re.I) and Path(sentence).parent.name == origin:\n"
            "        os.environ['CODEX_THREAD_ID'] = origin\n"
            "    else:\n        os.environ.pop('CODEX_THREAD_ID', None)\n    " + END + "\n")
    result[completion] = source
    question = speech_root.parents[1] / "question-reminders/scripts/remind-now.py"
    source = question.read_text()
    if BEGIN not in source:
        source = replace_once(source, "           'CODEX_SPEECH_DELIVERY':delivery}\n",
            "           'CODEX_SPEECH_DELIVERY':delivery, 'AGENTFLOW_OBS_QUESTION_ID':question_id}\n"
            "    " + BEGIN + "\n    # Exact question identity keeps its OBS reply with the existing asking agent.\n    " + END + "\n")
    result[question] = source
    for name in ("recover-missed-speech", "speak-action-reminder", "question-reminders"):
        path = speech_root.parents[1] / name / "SKILL.md"
        result[path] = compose_skill(path.read_text(), name)
        preferences = path.with_name("user-preferences.md")
        if not preferences.exists():
            result[preferences] = ("# Private preference evidence\n\n"
                "This is a router, not a public copy of personal history. For an unsettled\n"
                "speech/OBS preference, use the installed learned-user-preferences workflow\n"
                "to locate the private general record and query only the relevant topic.\n"
                "Do not create a project profile for an excluded upstream fork.\n")
    result[speech_root / "obs_reply_hook.py"] = (ROOT / "speech_hook.py").read_text()
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", type=Path, required=True, help="Reviewed private settings JSON")
    parser.add_argument("--speech-root", type=Path, default=Path.home() / ".codex/skills/speak-action-reminder/scripts")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    config = json.loads(args.settings.read_text())
    runtime = Path(config["runtime_directory"])
    if not runtime.is_absolute():
        raise ValueError("Runtime path must be absolute")
    sources = integrated_sources(args.speech_root)
    prior = {path: path.read_text() if path.exists() else None for path in sources}
    print(json.dumps({"mode": "apply" if args.apply else "dry-run", "runtime": str(runtime),
        "sharedFiles": [str(p) for p in sources], "nativeAppChanged": False, "OBSChanged": False}, indent=2))
    if not args.apply:
        return
    backup = runtime.parent / "Backups" / time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    backup.mkdir(parents=True, mode=0o700)
    backup_manifest = {}
    for path in sources:
        if path.exists():
            name = hashlib.sha256(str(path).encode()).hexdigest()[:8] + "-" + path.name
            shutil.copy2(path, backup / name)
            backup_manifest[str(path)] = name
    atomic_text(backup / "backup-manifest.json", json.dumps(backup_manifest, indent=2))
    hashes = {}
    for name in ("obs_replies.py", "mkv_window.py", "transcribe_current.py", "speech_hook.py", "audio_anchor.py", "consume-question.py", "skill_guidance.py", "README.md", "AGENT_SETUP.md"):
        data = (ROOT / name).read_bytes()
        hashes[name] = hashlib.sha256(data).hexdigest()
    # Versioned runtime copies preserve already-running finite workers on an
    # extension update. The pointer changes only after every source is ready.
    version = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()[:16]
    runtime = runtime.parent / (runtime.name.split("-", 1)[0] + "-" + version)
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    config["runtime_directory"] = str(runtime)
    for name in hashes:
        data = (ROOT / name).read_bytes()
        target = runtime / name
        target.write_bytes(data)
        target.chmod(0o600)
    for path, original in prior.items():
        if (path.read_text() if path.exists() else None) != original:
            raise ValueError("Shared speech source changed concurrently; installed sources preserved")
    # Publish the stdlib bootstrap before the queue imports it. All source
    # replacements are atomic, so another chat never reads a half-written file.
    ordered = sorted(sources, key=lambda path: (path.name != "obs_reply_hook.py", path.name == "speech_queue.py"))
    for path in ordered:
        atomic_text(path, sources[path], path.stat().st_mode & 0o777 if path.exists() else 0o600)
    current = runtime.parent / "runtime-current"
    temporary_link = current.with_name(current.name + "." + uuid.uuid4().hex)
    temporary_link.symlink_to(runtime, target_is_directory=True)
    os.replace(temporary_link, current)
    destination = Path.home() / "Library/Application Support/AgentFlow/OBS Replies/settings.json"
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if destination.exists() and destination.resolve() != args.settings.resolve():
        shutil.copy2(destination, backup / "settings.json")
    atomic_text(destination, json.dumps(config, indent=2))
    (backup / "installed-hashes.json").write_text(json.dumps(hashes, indent=2))
    print(json.dumps({"installed": True, "rollback": str(backup), "hashes": hashes}, indent=2))


if __name__ == "__main__":
    main()
