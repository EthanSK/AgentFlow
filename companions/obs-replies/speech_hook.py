"""Attach the optional OBS reply worker to the existing shared TTS queue.

This bootstrap uses only Python's standard library so the system Python that
owns notifications can launch the configured companion interpreter unchanged.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

SETTINGS = Path.home() / 'Library/Application Support/AgentFlow/OBS Replies/settings.json'
THREAD_ID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', re.I)


def private_json(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    fd = os.open(str(temporary), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump(value, file)
    os.replace(str(temporary), str(path))


def begin(command, environment):
    """Optional failure is a missed reply window, never failed/blocked speech."""
    write_fd = None
    try:
        config = json.loads(SETTINGS.read_text())
        if config.get('enabled') is not True:
            return None
        for key in ('state_directory', 'runtime_directory', 'python'):
            if not isinstance(config.get(key), str) or not Path(config[key]).is_absolute():
                return None
        thread = environment.get('CODEX_THREAD_ID', '')
        if not THREAD_ID.fullmatch(thread):
            return None
        index = next((i for i, part in enumerate(command) if part.endswith('/speak-with-youtube.swift')), None)
        if index is None or index + 1 >= len(command):
            return None
        with Path(command[index + 1]).open() as text_file:
            sentence = text_file.read(2049).strip()
        if not sentence or len(sentence) > 2048:
            return None
        root = Path(config['state_directory'])
        event_id = str(uuid.uuid4())
        event = root / 'events' / event_id
        event.mkdir(parents=True, mode=0o700)
        request = {'version': 1, 'eventID': event_id,
            'threadID': thread, 'spokenText': sentence,
            'createdWall': time.time(), 'createdUptime': time.clock_gettime(time.CLOCK_UPTIME_RAW)}
        question = environment.get('AGENTFLOW_OBS_QUESTION_ID')
        if question:
            request['questionID'] = question
        private_json(event / 'request.json', request)
        read_fd, write_fd = os.pipe()
        try:
            subprocess.Popen([config['python'], str(Path(config['runtime_directory']) / 'obs_replies.py'),
                'worker', '--event', str(event), '--settings', str(SETTINGS)], stdin=read_fd,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        finally:
            os.close(read_fd)
        return {'event': event, 'write_fd': write_fd, 'event_id': event_id,
                'latest_file': root / 'latest.json'}
    except (OSError, ValueError, KeyError, TypeError):
        if write_fd is not None:
            os.close(write_fd)
        return None


def finish(handle, outcome):
    if handle is None:
        return
    try:
        receipt = json.loads((handle['event'] / 'playback-end.json').read_text())
        payload = {'outcome': outcome.get('outcome'), 'returncode': outcome.get('returncode'),
            'cancelled': outcome.get('cancelled', False), 'playback': receipt}
        os.write(handle['write_fd'], (json.dumps(payload) + '\n').encode())
    except (OSError, ValueError):
        pass
    finally:
        os.close(handle['write_fd'])
