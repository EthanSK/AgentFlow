"""Locate the actual TTS tail inside OBS audio, without another model call.

Normalized FFT correlation anchors the reply to recorded sound rather than an
uncalibrated encoder clock. System audio is analysed locally and never uploaded.
"""
from __future__ import annotations

import numpy as np


def locate_playback_end(recorded: bytes, reference: bytes, *, sample_rate: int = 24000) -> dict:
    signal = np.frombuffer(recorded, dtype="<i2").astype(np.float64)
    template = np.frombuffer(reference, dtype="<i2").astype(np.float64)
    if not sample_rate / 2 <= len(template) <= 3 * sample_rate or len(signal) < len(template):
        raise ValueError("Insufficient bounded TTS reference for audio alignment")
    template -= np.mean(template)
    energy = float(np.dot(template, template))
    if energy <= len(template):
        raise ValueError("TTS reference has no reliable audio energy")
    size = len(signal) + len(template) - 1
    fft_size = 1 << (size - 1).bit_length()
    convolution = np.fft.irfft(np.fft.rfft(signal, fft_size) * np.fft.rfft(template[::-1], fft_size), fft_size)
    dots = convolution[len(template) - 1:len(signal)]
    squares = np.concatenate(([0.0], np.cumsum(signal * signal)))
    sums = np.concatenate(([0.0], np.cumsum(signal)))
    local_energy = squares[len(template):] - squares[:-len(template)]
    local_mean = sums[len(template):] - sums[:-len(template)]
    local_energy -= local_mean * local_mean / len(template)
    correlation = dots / np.sqrt(np.maximum(local_energy * energy, 1))
    index = int(np.argmax(correlation))
    score = float(correlation[index])
    if score < 0.75:
        raise ValueError("Played TTS could not be confidently located in the OBS output track")
    outside = correlation.copy()
    radius = round(sample_rate * 0.05)
    outside[max(0, index - radius):index + radius + 1] = -1
    if np.max(outside, initial=-1) >= score * 0.95:
        raise ValueError("The recorded TTS match is ambiguous")
    return {"endOffsetSeconds": (index + len(template)) / sample_rate,
            "correlation": score, "resolutionSeconds": 1 / sample_rate,
            "referenceSeconds": len(template) / sample_rate}
