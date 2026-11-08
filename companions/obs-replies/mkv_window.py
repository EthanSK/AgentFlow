"""Read a recent microphone window from a growing OBS MKV without scanning it.

The reply worker copies only the small Matroska header and complete recent
clusters into ffmpeg's stdin. The original recording is always read-only.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
import subprocess


class WindowUnavailable(ValueError):
    """The bounded readable tail cannot prove the requested interval yet."""


def vint(data: bytes, offset: int, *, identifier: bool = False) -> tuple[int, int]:
    if offset >= len(data) or not data[offset]:
        raise WindowUnavailable("Incomplete EBML integer")
    width = 9 - data[offset].bit_length()
    if width > (4 if identifier else 8) or offset + width > len(data):
        raise WindowUnavailable("Invalid EBML integer")
    value = int.from_bytes(data[offset:offset + width], "big")
    return (value if identifier else value & ((1 << (7 * width)) - 1)), width


def element(data: bytes, offset: int) -> tuple[int, int, int]:
    kind, id_width = vint(data, offset, identifier=True)
    size, size_width = vint(data, offset + id_width)
    if size == (1 << (7 * size_width)) - 1:
        raise WindowUnavailable("Unknown-sized child element")
    begin = offset + id_width + size_width
    return kind, begin, begin + size


@dataclass(frozen=True)
class Cluster:
    offset: int
    end: int
    timecode: int


def recording_header(data: bytes) -> tuple[bytes, float]:
    """Walk actual top-level elements; codec bytes are never header markers."""
    kind, _, cursor = element(data, 0)
    if kind != 0x1A45DFA3:
        raise WindowUnavailable("Not an EBML recording")
    kind, id_width = vint(data, cursor, identifier=True)
    if kind != 0x18538067:
        raise WindowUnavailable("Missing Matroska segment")
    _, size_width = vint(data, cursor + id_width)
    size_at = cursor + id_width
    cursor = size_at + size_width
    # The slice has different physical offsets. Make its Segment streaming,
    # whether the original writer used a finite or unknown length.
    prefix = bytearray(data)
    prefix[size_at:cursor] = bytes([0xFF >> (size_width - 1)]) + b"\xff" * (size_width - 1)
    scale = 0.001
    tracks = False
    while cursor < len(data):
        kind, begin, end = element(data, cursor)
        if kind == 0x1F43B675:
            if not tracks:
                raise WindowUnavailable("Missing recording tracks")
            return bytes(prefix[:cursor]), scale
        if end > len(data):
            raise WindowUnavailable("Header exceeds bounded read")
        if kind == 0x1654AE6B:
            tracks = True
        if kind == 0x1549A966:
            child = begin
            while child < end:
                child_kind, start, finish = element(data, child)
                if finish > end:
                    raise WindowUnavailable("Invalid recording information")
                if child_kind == 0x2AD7B1:
                    scale = int.from_bytes(data[start:finish], "big") / 1e9
                child = finish
        cursor = end
    raise WindowUnavailable("Missing first cluster")


def complete_clusters(tail: bytes) -> list[Cluster]:
    """Require structural neighbours, not a coincidental compressed-byte match."""
    marker = b"\x1f\x43\xb6\x75"
    candidates: list[Cluster] = []
    cursor = 0
    while (cursor := tail.find(marker, cursor)) >= 0:
        try:
            _, begin, end = element(tail, cursor)
            if end <= len(tail):
                child = begin
                # OBS writes CRC-32 before Timecode in real growing MKVs.
                kind, start, finish = element(tail, child)
                if kind == 0xBF and finish - start == 4:
                    kind, start, finish = element(tail, finish)
                if kind == 0xE7 and 1 <= finish - start <= 8 and finish <= end:
                    candidates.append(Cluster(cursor, end, int.from_bytes(tail[start:finish], "big")))
        except WindowUnavailable:
            pass
        cursor += len(marker)
    if len(candidates) < 2:
        raise WindowUnavailable("Need adjacent complete recording clusters")
    chains: list[list[Cluster]] = []
    for cluster in candidates:
        if chains and chains[-1][-1].end == cluster.offset and chains[-1][-1].timecode <= cluster.timecode:
            chains[-1].append(cluster)
        else:
            chains.append([cluster])
    chain = max(chains, key=len)
    if len(chain) < 2:
        raise WindowUnavailable("No validated contiguous cluster chain")
    return chain


def extract_pcm(source: Path, *, start: float, duration: float, audio_index: int,
                ffmpeg: str, expected_identity: tuple[int, int],
                max_tail_bytes: int = 64 * 1024 * 1024) -> tuple[bytes, dict]:
    if start < 0 or not 0 < duration <= 15 or audio_index < 0:
        raise ValueError("Invalid bounded microphone interval")
    with source.open("rb") as recording:
        before = os.fstat(recording.fileno())
        if (before.st_dev, before.st_ino) != expected_identity:
            raise WindowUnavailable("Recording identity changed")
        header, scale = recording_header(recording.read(1024 * 1024))
        size = before.st_size
        tail_offset = max(len(header), size - min(4 * 1024 * 1024, max_tail_bytes))
        recording.seek(tail_offset)
        tail = recording.read(min(max_tail_bytes, size - tail_offset))
        while True:
            chain = []
            try:
                chain = complete_clusters(tail)
                eligible = [i for i, c in enumerate(chain) if c.timecode * scale <= start]
                if eligible and chain[-1].timecode * scale >= start + duration:
                    break
            except WindowUnavailable:
                pass
            if chain and chain[-1].timecode * scale < start + duration:
                raise WindowUnavailable("Recording has not flushed the end of this audio window")
            expanded_offset = max(len(header), size - min(max_tail_bytes, len(tail) * 2))
            if expanded_offset >= tail_offset:
                raise WindowUnavailable("Requested interval is outside the complete readable tail")
            # Retain what we already read; fetch only the missing prefix.
            recording.seek(expanded_offset)
            tail = recording.read(tail_offset - expanded_offset) + tail
            tail_offset = expanded_offset
        first = eligible[-1]
        # Include preceding packets for decoder state and end at a complete
        # later cluster. AAC sample trimming, not cluster boundaries, cuts audio.
        first = max(0, first - 1)
        last = next(i for i, c in enumerate(chain) if c.timecode * scale >= start + duration)
        selected = header + tail[chain[first].offset:chain[last].end]
    command = [ffmpeg, "-nostdin", "-v", "error", "-threads", "1", "-copyts",
               "-i", "pipe:0", "-map", f"0:a:{audio_index}", "-vn",
               "-af", f"atrim=start={start:.9f}:duration={duration:.9f},asetpts=PTS-STARTPTS",
               "-ac", "1", "-ar", "24000", "-f", "s16le", "pipe:1"]
    result = subprocess.run(command, input=selected, capture_output=True, timeout=12, check=False)
    if result.returncode:
        raise WindowUnavailable("Bounded recording audio decode failed")
    expected = round(duration * 48000)
    if abs(len(result.stdout) - expected) > 480:
        raise WindowUnavailable("Decoded audio does not cover the complete requested interval")
    return result.stdout[:expected], {"bytesRead": len(tail) + len(header),
        "bytesDecoded": len(selected), "sourceSize": size, "start": start,
        "duration": len(result.stdout) / 48000, "audioIndex": audio_index,
        "recordingTimestampResolutionSeconds": scale}
