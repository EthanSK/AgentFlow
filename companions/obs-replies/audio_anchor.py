"""Locate reply timing inside OBS audio, without another model call.

Normalized FFT correlation anchors the reply to recorded sound rather than an
uncalibrated encoder clock. All analysis is local; nothing here is uploaded.

GetRecordStatus.outputDuration counts frames already handed to the muxer, so it
trails the recorded audio timeline. A live measurement put that bias at +1.14s,
next to OBS's logged 960ms maximum audio buffering. It is NOT an exact recording
position, which is why both anchors below measure it instead of assuming it.
"""
from __future__ import annotations

from typing import Sequence

import numpy as np

# Bounds around the frame-count clock, seconds. Asymmetric because that clock
# lags the file; the late side must clear the measured bias with real margin.
ALIGN_EARLY_SECONDS = 1.5
ALIGN_LATE_SECONDS = 3.5
_ENVELOPE_HOP = 0.01
_METER_SECONDS = 0.05
_MIN_METER_SAMPLES = 100
_MIN_METER_SPAN = 8.0


class SystemOutputSilent(ValueError):
    """The system-output track holds exact zeros while TTS demonstrably played.

    Distinct from a failed match. A dead capture (live case: ScreenCaptureKit
    stream error -3805, never restarted by OBS) has no waveform to compare, so
    "could not be located" misdescribes it. Only this proven absence of signal
    may select the microphone-timeline anchor; a real mismatch stays fatal.
    """


def locate_playback_end(recorded: bytes, reference: bytes, *, sample_rate: int = 24000) -> dict:
    signal = np.frombuffer(recorded, dtype="<i2").astype(np.float64)
    template = np.frombuffer(reference, dtype="<i2").astype(np.float64)
    if not sample_rate / 2 <= len(template) <= 3 * sample_rate or len(signal) < len(template):
        raise ValueError("Insufficient bounded TTS reference for audio alignment")
    template -= np.mean(template)
    energy = float(np.dot(template, template))
    if energy <= len(template):
        raise ValueError("TTS reference has no reliable audio energy")
    if not np.any(signal):
        raise SystemOutputSilent("The OBS system-output track was digital silence while the announcement played")
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


def _peak_envelope_db(signal: np.ndarray, sample_rate: int) -> np.ndarray:
    """50ms peak every 10ms, mirroring what one OBS meter event summarizes."""
    hop = round(sample_rate * _ENVELOPE_HOP)
    count = len(signal) // hop
    bins = np.abs(signal[:count * hop]).reshape(count, hop).max(axis=1)
    width = round(_METER_SECONDS / _ENVELOPE_HOP)
    peaks = np.lib.stride_tricks.sliding_window_view(bins, width).max(axis=1)
    return 20 * np.log10(np.maximum(peaks, 3.2768) / 32768)


def locate_mic_timeline(recorded: bytes, recorded_start: float, meter_times: Sequence[float],
                        meter_levels: Sequence[float], *, sample_rate: int = 24000) -> dict:
    """Measure where live microphone levels actually landed in the recorded mic.

    OBS's meter events are stamped on the shared uptime clock as the sound
    arrives; the recorded track is the very audio that will be transcribed.
    Their correlation maps uptime onto the file with no system-output track,
    and is real evidence rather than a clock assumption. meter_times must
    already be expressed on the frame-count clock. The reported offset is what
    that clock is missing. It proves timeline alignment only: it does not prove
    the announcement was audible or recorded, and callers must say so.
    """
    signal = np.frombuffer(recorded, dtype="<i2").astype(np.float64)
    if not len(signal) or not np.any(signal):
        raise ValueError("Recorded microphone audio has no signal to align")
    envelope = _peak_envelope_db(signal, sample_rate)
    times = np.asarray(meter_times, dtype=np.float64)
    levels = np.asarray(meter_levels, dtype=np.float64)
    # Keep only meter events whose candidate positions exist at every lag, so
    # each lag is scored on identical samples and none is favoured by coverage.
    last = recorded_start + len(envelope) * _ENVELOPE_HOP
    usable = (times - _METER_SECONDS - ALIGN_EARLY_SECONDS >= recorded_start
              ) & (times - _METER_SECONDS + ALIGN_LATE_SECONDS < last)
    times, levels = times[usable], levels[usable]
    if len(times) < _MIN_METER_SAMPLES or times[-1] - times[0] < _MIN_METER_SPAN:
        raise ValueError("Too little live microphone metering to align the recording")
    meter = 20 * np.log10(np.maximum(levels, 1e-4))
    if float(np.std(meter)) < 0.5:
        raise ValueError("Live microphone level was too uniform to align the recording")
    meter = meter - meter.mean()
    base = (times - _METER_SECONDS - recorded_start) / _ENVELOPE_HOP
    lags = np.arange(-round(ALIGN_EARLY_SECONDS / _ENVELOPE_HOP), round(ALIGN_LATE_SECONDS / _ENVELOPE_HOP) + 1)
    scores = np.empty(len(lags))
    for position, lag in enumerate(lags):
        values = envelope[np.round(base + lag).astype(int)]
        values = values - values.mean()
        scores[position] = (meter @ values) / np.sqrt((meter @ meter) * (values @ values) + 1e-9)
    best = int(np.argmax(scores))
    score = float(scores[best])
    if score < 0.75:
        raise ValueError(f"Live microphone levels could not be confidently located in the recording (correlation {score:.2f})")
    if best < 5 or best >= len(lags) - 5:
        # A peak pinned to the search edge means the true offset may lie beyond it.
        raise ValueError("Recorded microphone offset is outside the bounded alignment search")
    away = np.abs(lags - lags[best]) * _ENVELOPE_HOP >= 0.25
    runner_up = float(np.max(scores[away], initial=-1))
    if runner_up >= score * 0.85:
        raise ValueError("The recorded microphone alignment is ambiguous")
    return {"offsetSeconds": float(lags[best]) * _ENVELOPE_HOP, "correlation": score,
            "runnerUpCorrelation": runner_up, "meterSamples": int(len(times)),
            "resolutionSeconds": _ENVELOPE_HOP, "meterIntervalSeconds": _METER_SECONDS}


def reply_edges(pcm: bytes, *, sample_rate: int = 24000) -> dict:
    """Report sound touching either edge of the fixed window, without moving it.

    Someone answering the moment speech ends can start inside the announcement's
    tail. The enabled capture still begins at the end of TTS, so a clipped first
    word stays clipped; this tells the reader not to invent what it lost.
    """
    signal = np.frombuffer(pcm, dtype="<i2").astype(np.float64)
    hop = round(sample_rate * _METER_SECONDS)
    count = len(signal) // hop
    if count < 20:
        return {"startActive": False, "endActive": False}
    rms = np.sqrt(np.mean(signal[:count * hop].reshape(count, hop) ** 2, axis=1))
    level = 20 * np.log10(np.maximum(rms, 1) / 32768)
    active = level >= max(float(np.percentile(level, 20)) + 12, -55)
    return {"startActive": bool(active[:5].any()), "endActive": bool(active[-5:].any())}
