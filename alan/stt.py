"""Speech-to-text via the faster-whisper server (OpenAI-style API)."""

from __future__ import annotations

import logging
from pathlib import Path

import requests

from .config import Config

log = logging.getLogger(__name__)

TIMEOUT_SECONDS = 60
_session = requests.Session()


def transcribe(path: Path, cfg: Config) -> str:
    """Send a WAV file to Whisper and return the transcribed text ("" on failure)."""
    try:
        with open(path, "rb") as f:
            response = _session.post(
                cfg.whisper_url,
                files={"file": f},
                data={"model": cfg.whisper_model},
                timeout=TIMEOUT_SECONDS,
            )
        response.raise_for_status()
        return str(response.json().get("text", "")).strip()
    except Exception:
        log.exception("Transcription failed (%s)", cfg.whisper_url)
        return ""
