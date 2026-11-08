"""Verify local audio alignment with delay, attenuation, noise and ambiguity."""
import unittest
import numpy as np
from audio_anchor import SystemOutputSilent, locate_mic_timeline, locate_playback_end, reply_edges


def pcm(samples):
    return np.asarray(np.clip(samples, -32768, 32767), dtype="<i2").tobytes()


class AnchorTests(unittest.TestCase):
    def setUp(self):
        self.rate = 24000
        self.random = np.random.default_rng(74)
        self.reference = self.random.normal(0, 3500, 24000)

    def test_locates_delayed_attenuated_audio_to_one_sample(self):
        signal = self.random.normal(0, 10, 4 * self.rate)
        start = 29341
        signal[start:start + len(self.reference)] += self.reference * 0.19
        result = locate_playback_end(pcm(signal), pcm(self.reference))
        self.assertAlmostEqual(result["endOffsetSeconds"], (start + self.rate) / self.rate, places=6)
        self.assertGreater(result["correlation"], 0.99)

    def test_unrelated_audio_cannot_anchor_reply(self):
        signal = self.random.normal(0, 3500, 4 * self.rate)
        with self.assertRaises(ValueError):
            locate_playback_end(pcm(signal), pcm(self.reference))

    def test_repeated_playback_is_ambiguous(self):
        signal = np.zeros(4 * self.rate)
        signal[1000:25000] = self.reference
        signal[50000:74000] = self.reference
        with self.assertRaises(ValueError):
            locate_playback_end(pcm(signal), pcm(self.reference))

    def test_silent_reference_is_not_an_anchor(self):
        with self.assertRaises(ValueError):
            locate_playback_end(pcm(self.reference), bytes(48000))

    def test_dead_system_capture_is_distinct_from_a_failed_match(self):
        # The live failure: every window read exact zeros after SCK error -3805.
        with self.assertRaises(SystemOutputSilent):
            locate_playback_end(bytes(5 * 48000), pcm(self.reference))

    def test_unrelated_audio_is_a_mismatch_not_dead_capture(self):
        signal = self.random.normal(0, 3500, 4 * self.rate)
        with self.assertRaises(ValueError) as caught:
            locate_playback_end(pcm(signal), pcm(self.reference))
        self.assertNotIsInstance(caught.exception, SystemOutputSilent)


class MicTimelineTests(unittest.TestCase):
    """Meter events stand at nominal time; the sound sits later in the file."""
    rate = 24000
    read_from = 100.0
    read_seconds = 16.5

    def setUp(self):
        self.random = np.random.default_rng(91)

    def speech(self):
        # Irregular syllable-like bursts over a room-noise floor.
        total = round(40 * self.rate)
        gain = np.full(total, 60.0)
        cursor = 0
        while cursor < total:
            cursor += int(self.random.uniform(0.08, 0.7) * self.rate)
            length = int(self.random.uniform(0.06, 0.5) * self.rate)
            gain[cursor:cursor + length] = self.random.uniform(600, 6000)
        return self.random.normal(0, 1, total) * gain

    def meters(self, source, begin, first, last):
        # What OBS reports: each event's peak over the preceding 50ms.
        times = np.arange(first, last, 0.0536)
        levels = []
        for stamp in times:
            stop = round((stamp - begin) * self.rate)
            levels.append(np.abs(source[stop - 1200:stop]).max() / 32768)
        return times, levels

    def scenario(self, true_offset):
        source = self.speech()
        # Sample n of source is the sound on the nominal timeline at 90 + n/rate.
        window = source[round((self.read_from - 90 - true_offset) * self.rate):]
        recorded = window[:round(self.read_seconds * self.rate)]
        times, levels = self.meters(source, 90, 101.5, 116.5)
        return pcm(recorded), times, levels

    def test_measures_the_real_frame_clock_bias(self):
        recorded, times, levels = self.scenario(1.14)
        result = locate_mic_timeline(recorded, self.read_from, times, levels)
        self.assertAlmostEqual(result["offsetSeconds"], 1.14, delta=0.02)
        self.assertGreater(result["correlation"], 0.9)

    def test_unrelated_microphone_audio_cannot_anchor_reply(self):
        recorded, times, _ = self.scenario(1.14)
        _, _, other = self.scenario(0.4)
        with self.assertRaises(ValueError):
            locate_mic_timeline(recorded, self.read_from, times, other)

    def test_offset_beyond_search_is_rejected_not_clamped(self):
        recorded, times, levels = self.scenario(6.0)
        with self.assertRaises(ValueError):
            locate_mic_timeline(recorded, self.read_from, times, levels)

    def test_flat_meter_and_silent_track_stop(self):
        recorded, times, _ = self.scenario(1.14)
        with self.assertRaisesRegex(ValueError, "too uniform"):
            locate_mic_timeline(recorded, self.read_from, times, [0.1] * len(times))
        with self.assertRaisesRegex(ValueError, "no signal"):
            locate_mic_timeline(bytes(len(recorded)), self.read_from, times, [0.1] * len(times))

    def test_truncated_metering_stops(self):
        recorded, times, levels = self.scenario(1.14)
        with self.assertRaisesRegex(ValueError, "Too little"):
            locate_mic_timeline(recorded, self.read_from, times[:40], levels[:40])


class ReplyEdgeTests(unittest.TestCase):
    rate = 24000

    def window(self, *bursts):
        random = np.random.default_rng(5)
        signal = random.normal(0, 40, 15 * self.rate)
        for begin, end in bursts:
            signal[round(begin * self.rate):round(end * self.rate)] += random.normal(0, 5000, round((end - begin) * self.rate))
        return pcm(signal)

    def test_reply_touching_the_start_is_flagged(self):
        self.assertEqual(reply_edges(self.window((0, 0.7))), {"startActive": True, "endActive": False})

    def test_reply_touching_the_end_is_flagged(self):
        self.assertEqual(reply_edges(self.window((14.4, 15))), {"startActive": False, "endActive": True})

    def test_contained_reply_and_silence_touch_neither_edge(self):
        for audio in (self.window((3, 5)), self.window(), bytes(15 * 48000)):
            self.assertEqual(reply_edges(audio), {"startActive": False, "endActive": False})


if __name__ == "__main__":
    unittest.main()
