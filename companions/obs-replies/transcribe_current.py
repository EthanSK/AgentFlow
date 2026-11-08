"""Transcribe one bounded OBS reply with Agent Flow's current voice model.

Credentials stay in this process. This independent adapter never changes Mode,
uses the normal paste pipeline, or adds captured screen/selection hints to ASR.
"""
from __future__ import annotations

import asyncio
import base64
from dataclasses import dataclass, field
import json
from pathlib import Path
import plistlib
from typing import Any

import websockets


@dataclass(frozen=True)
class VoiceSettings:
    model: str
    language: str
    key: str = field(repr=False)


def current_settings(home: Path) -> VoiceSettings:
    preferences = plistlib.loads((home / "Library/Preferences/com.ethansk.VoiceInkPlusPlus.plist").read_bytes())
    modes = preferences.get("modeConfigurationsV2", [])
    if isinstance(modes, (str, bytes)):
        modes = json.loads(modes)
    if not isinstance(modes, list):
        raise ValueError("Unrecognized Agent Flow Mode configuration")
    mode = next((m for m in modes if m.get("id") == preferences.get("activeConfigurationId") and m.get("isEnabled") is True), None)
    if mode is None:
        mode = next((m for m in modes if m.get("isDefault") is True and m.get("isEnabled") is True), {})
    model = mode.get("selectedTranscriptionModelName") or preferences.get("CurrentTranscriptionModel")
    language = mode.get("selectedLanguage") or preferences.get("SelectedLanguage") or "en"
    key = preferences.get("LocalKeychain_openAIAPIKey")
    if isinstance(key, bytes):
        key = key.decode()
    if model != "gpt-live-transcribe" or not isinstance(key, str) or not key:
        raise ValueError("The current Agent Flow model/credential has no supported reply adapter; no substitution")
    return VoiceSettings(model, language, key)


def transcription_update(settings: VoiceSettings) -> dict:
    return {"type": "session.update", "session": {"type": "transcription", "audio": {"input": {
        "format": {"type": "audio/pcm", "rate": 24000},
        "transcription": {"model": settings.model, "languages": [settings.language], "delay": "xhigh"},
        "turn_detection": None}}}}


def accept_completion(event: dict, item_id: str | None, seconds: float) -> dict:
    if not item_id or event.get("item_id") != item_id:
        raise ValueError("Transcription did not match the committed reply audio")
    usage = event.get("usage", {})
    if usage.get("type") != "duration" or not isinstance(usage.get("seconds"), (int, float)) or abs(usage["seconds"] - seconds) > 1:
        raise ValueError("Provider did not confirm complete reply-window coverage")
    text = event.get("transcript")
    if not isinstance(text, str):
        raise ValueError("Provider returned an invalid reply transcript")
    # An acknowledged empty transcript is a valid no-speech outcome, not an
    # API failure and not permission to hallucinate a reply or change models.
    return {"status": "transcribed" if text.strip() else "no_speech", "text": text.strip(),
            "usage": usage, "itemID": item_id}


async def transcribe(pcm: bytes, settings: VoiceSettings) -> dict[str, Any]:
    return await asyncio.wait_for(_transcribe(pcm, settings), 45)


async def _transcribe(pcm: bytes, settings: VoiceSettings) -> dict[str, Any]:
    if not pcm or len(pcm) % 2 or len(pcm) > 15 * 48000:
        raise ValueError("Reply audio must be PCM16 mono, at most15 seconds")
    seconds = len(pcm) / 48000
    if not any(pcm):
        raise ValueError("OBS microphone track contains only digital zero; source health is unverified")
    # The official append/commit workflow does not mandate a replay sleep.
    # Verify item identity and complete duration instead of trusting a prefix.
    async with websockets.connect("wss://api.openai.com/v1/realtime?intent=transcription",
            additional_headers={"Authorization": "Bearer " + settings.key},
            open_timeout=10, max_size=2 * 1024 * 1024) as socket:
        await socket.send(json.dumps(transcription_update(settings)))
        item_id = None
        sent_audio = False
        async for raw in socket:
            event = json.loads(raw)
            kind = event.get("type")
            if kind in ("error", "conversation.item.input_audio_transcription.failed"):
                # Never propagate raw provider messages; they can echo audio
                # context or credentials. The stable error code is enough.
                code = event.get("error", {}).get("code", "unknown")
                raise ValueError("Transcription provider error: " + str(code)[:80])
            if kind == "session.updated" and not sent_audio:
                confirmed = event.get("session", {}).get("audio", {}).get("input", {}).get("transcription", {}).get("model")
                if confirmed != settings.model:
                    raise ValueError("Provider did not acknowledge the current Agent Flow model")
                sent_audio = True
                for offset in range(0, len(pcm), 9600):
                    await socket.send(json.dumps({"type": "input_audio_buffer.append",
                        "audio": base64.b64encode(pcm[offset:offset + 9600]).decode()}))
                await socket.send(json.dumps({"type": "input_audio_buffer.commit"}))
            elif kind == "input_audio_buffer.committed":
                if item_id is not None:
                    raise ValueError("Unexpected second committed reply item")
                item_id = event.get("item_id")
            elif kind == "conversation.item.input_audio_transcription.completed":
                return {**accept_completion(event, item_id, seconds), "seconds": seconds,
                        "model": settings.model, "language": settings.language, "delay": "xhigh",
                        "contextSupplied": False}
    raise ValueError("Provider closed before completing the reply window")
