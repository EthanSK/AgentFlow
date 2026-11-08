"""Verify local audio alignment with delay, attenuation, noise and ambiguity."""
import unittest
import numpy as np
from audio_anchor import locate_playback_end


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


if __name__ == "__main__":
    unittest.main()
