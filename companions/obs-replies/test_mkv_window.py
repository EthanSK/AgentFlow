"""Prove recent-cluster extraction matches ordinary full-file audio decoding."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from mkv_window import extract_pcm, recording_header, complete_clusters, WindowUnavailable


class MKVTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = shutil.which("ffmpeg")
        if not cls.ffmpeg:
            raise unittest.SkipTest("ffmpeg not installed on this test worker")
        cls.directory = tempfile.TemporaryDirectory()
        cls.source = Path(cls.directory.name) / "growing.mkv"
        subprocess.run([cls.ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
            "color=size=16x16:rate=5:duration=24", "-f", "lavfi", "-i",
            "sine=frequency=439:sample_rate=24000:duration=24", "-c:v", "libx264", "-threads", "1",
            "-c:a", "pcm_s16le", "-cluster_time_limit", "1000", "-live", "1", str(cls.source)],
            capture_output=True, check=True, timeout=15)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_splice_matches_reference_samples(self):
        stat = self.source.stat()
        audio, report = extract_pcm(self.source, start=4.25, duration=15, audio_index=0,
            ffmpeg=self.ffmpeg, expected_identity=(stat.st_dev, stat.st_ino))
        reference = subprocess.run([self.ffmpeg, "-nostdin", "-v", "error", "-copyts", "-i", str(self.source),
            "-map", "0:a:0", "-af", "atrim=start=4.25:duration=15,asetpts=PTS-STARTPTS",
            "-ac", "1", "-ar", "24000", "-f", "s16le", "pipe:1"], capture_output=True, check=True, timeout=10).stdout
        # MKV's millisecond block timestamps lose a fractional sample phase
        # when decoding begins at a later cluster. Require exact shared samples
        # with at most one recorded timestamp tick of phase uncertainty.
        matches = []
        for shift in range(-24, 25):
            left = audio[max(shift, 0) * 2:len(audio) + min(shift, 0) * 2]
            right = reference[max(-shift, 0) * 2:len(reference) - max(shift, 0) * 2]
            if left == right:
                matches.append(shift)
        self.assertTrue(matches, "Splice changed samples beyond Matroska's1ms timestamp precision")
        self.assertEqual(len(audio), 15 * 48000)
        self.assertLessEqual(report["bytesRead"], 64 * 1024 * 1024 + 1024 * 1024)

    def test_replaced_recording_cannot_be_read(self):
        with self.assertRaises(WindowUnavailable):
            extract_pcm(self.source, start=4, duration=15, audio_index=0,
                ffmpeg=self.ffmpeg, expected_identity=(0, 0))

    def test_incomplete_tail_is_not_transcribed(self):
        stat = self.source.stat()
        with self.assertRaises(WindowUnavailable):
            extract_pcm(self.source, start=20, duration=15, audio_index=0,
                ffmpeg=self.ffmpeg, expected_identity=(stat.st_dev, stat.st_ino))

    def test_crc_clusters_are_recognized(self):
        data = self.source.read_bytes()
        header, scale = recording_header(data[:1024 * 1024])
        clusters = complete_clusters(data[len(header):])
        self.assertGreaterEqual(len(clusters), 3)
        self.assertEqual(scale, 0.001)


if __name__ == "__main__":
    unittest.main()
