"""Run the whole finite worker against deterministic OBS/audio/provider boundaries."""
import asyncio
from contextlib import ExitStack
import io
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

import obs_replies as replies
from transcribe_current import VoiceSettings


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    async def run_window(self, *, question=False, text='Yes, keep that setting.', outcome='spoken'):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            home = Path(directory)
            event = home / 'events' / 'event1'
            event.mkdir(parents=True)
            thread = '01a0f279-0db9-7df3-b65b-70b67e51d721'
            request = {'threadID': thread, 'eventID': event.name, 'spokenText': 'Should I keep this setting?'}
            if question:
                request['questionID'] = 'question1'
                root = home / '.codex/state/question-reminders' / thread
                root.mkdir(parents=True)
                (root / 'pending-questions.json').write_text(json.dumps({'thread_id': thread,
                    'questions': [{'question_id': 'question1', 'status': 'open'}]}))
            (event / 'request.json').write_text(json.dumps(request))
            config = {'obs_config': '/private/config', 'ffmpeg': '/bin/ffmpeg', 'input_name': 'mic'}
            snapshot = {'path': '/recording.mkv', 'identity': [1, 2], 'audioIndex': 2,
                'systemAudioIndex': 1, 'frameSeconds': 1/30, 'otherRoutedSources': [],
                'clock': {'uptime': 90, 'media': 190, 'wall': 990, 'roundTrip': .002}}
            later = {**snapshot, 'clock': {'uptime': 116, 'media': 216, 'wall': 1016, 'roundTrip': .002}}
            class FakeOBS:
                invalidated = False
                meter_samples = [(100 + n*.05, {'mic': .1}) for n in range(301)]
                async def __aenter__(self): return self
                async def __aexit__(self, *args): pass
                async def clock(self): return {'uptime': 101, 'media': 201, 'wall': 1001, 'roundTrip': .002}
            class FakeGuard:
                allowed = True
                async def __aenter__(self): return self
                async def __aexit__(self, *args): pass
            receipt = {'outcome': outcome, 'returncode': 0, 'cancelled': False,
                'playback': {'endedUptime': 100, 'endedWall': 1000, 'returncode': 0, 'reason': 'exit'}}
            provider = AsyncMock(return_value={'status': 'transcribed' if text else 'no_speech',
                'text': text, 'model': 'gpt-live-transcribe'})
            decode = Mock(return_value=(b'\1\0'*360000, {'duration': 15}))
            dispatch = Mock()
            for target, value in [
                ('settings', Mock(return_value=config)), ('OBS', Mock(return_value=FakeOBS())),
                ('CaptureGuard', Mock(return_value=FakeGuard())),
                ('snapshot', AsyncMock(side_effect=[snapshot, later])),
                ('current_settings', Mock(return_value=VoiceSettings('gpt-live-transcribe', 'en', 'test'))),
                ('chat_cursor', Mock(return_value=('unused', 1, 0))),
                ('chat_has_new_user_message', Mock(return_value=False)),
                ('is_current', Mock(return_value=True)), ('uptime', Mock(return_value=116)),
                ('extract_pcm', decode), ('locate_playback_end', Mock(return_value={'endOffsetSeconds': 3.5, 'score': 1})),
                ('transcribe', provider), ('dispatch_candidate', dispatch),
            ]: stack.enter_context(patch.object(replies, target, value))
            stack.enter_context(patch.object(replies.Path, 'home', return_value=home))
            stack.enter_context(patch.object(replies.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(json.dumps(receipt).encode()+b'\n'))))
            stack.enter_context(patch.object(replies.subprocess, 'run', return_value=SimpleNamespace(stdout=b'\1\0'*48000)))
            if outcome != 'spoken':
                with self.assertRaisesRegex(ValueError, 'skipped, failed or interrupted'):
                    await replies.worker(event, home/'settings.json')
                provider.assert_not_awaited()
                decode.assert_not_called()
                dispatch.assert_not_called()
                return
            await replies.worker(event, home/'settings.json')
            self.assertEqual(decode.call_count, 2)
            self.assertEqual(decode.call_args.kwargs['start'], 200)
            self.assertEqual(decode.call_args.kwargs['duration'], 15)
            self.assertEqual(decode.call_args.kwargs['audio_index'], 2)
            provider.assert_awaited_once()
            self.assertEqual(json.loads((event/'timing.json').read_text())['listeningEndUptime'], 115)
            offer = home/'.codex/state/question-reminders'/thread/'reply-windows/question1.json'
            if text and not replies.suspect_transcript(text, request['spokenText']):
                if question:
                    self.assertEqual(json.loads(offer.read_text())['transcript']['text'], text)
                    dispatch.assert_not_called()
                else:
                    dispatch.assert_called_once()
            else:
                dispatch.assert_not_called()
                self.assertFalse(offer.exists())

    async def test_complete_question_reply_is_offered_to_waiting_agent(self):
        await self.run_window(question=True)

    async def test_complete_notification_reply_routes_to_exact_origin(self):
        await self.run_window()

    async def test_no_speech_never_dispatches(self):
        await self.run_window(text='')

    async def test_announcement_echo_never_dispatches(self):
        await self.run_window(text='Should I keep this setting?')

    async def test_interrupted_speech_never_reads_reply_audio(self):
        await self.run_window(outcome='cancelled')


if __name__ == '__main__':
    unittest.main()
