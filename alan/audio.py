"""Microphone capture (arecord) and speaker playback (pw-play / aplay)."""

from __future__ import annotations

import logging
import re
import shutil
import subprocess
from pathlib import Path

from .config import Config

log = logging.getLogger(__name__)

FALLBACK_INPUT = "hw:2,0"
_CARD_RE = re.compile(r"^card\s+(\d+):.*?device\s+(\d+):")


def detect_input_device(configured: str) -> str:
    """Resolve the ALSA capture device.

    ``auto`` picks the first ``arecord -l`` card whose line mentions "USB";
    any other value is returned unchanged.
    """
    if configured.strip().lower() != "auto":
        return configured
    try:
        result = subprocess.run(
            ["arecord", "-l"], capture_output=True, text=True, timeout=10
        )
        for line in result.stdout.splitlines():
            if "USB" not in line:
                continue
            match = _CARD_RE.match(line.strip())
            if match:
                device = f"hw:{match.group(1)},{match.group(2)}"
                log.info("Detected USB microphone: %s (%s)", device, line.strip())
                return device
    except (OSError, subprocess.SubprocessError) as exc:
        log.warning("Could not run 'arecord -l': %s", exc)
    log.warning("No USB microphone found; falling back to %s", FALLBACK_INPUT)
    return FALLBACK_INPUT


def record(path: Path, cfg: Config) -> bool:
    """Record ``cfg.record_seconds`` of mono S16_LE audio to ``path``."""
    cmd = [
        "arecord", "-D", cfg.audio_input, "-c", "1", "-r", str(cfg.sample_rate),
        "-f", "S16_LE", "-d", str(cfg.record_seconds), "-q", str(path),
    ]
    try:
        result = subprocess.run(cmd)
    except OSError as exc:
        log.error("Recording failed: %s", exc)
        return False
    if result.returncode != 0:
        log.error("arecord exited with code %d (device %s)", result.returncode, cfg.audio_input)
        return False
    return True


def resolve_player(cfg: Config) -> str:
    """Return the playback command: pw-play if available, else aplay, when ``auto``."""
    if cfg.audio_player.strip().lower() != "auto":
        return cfg.audio_player
    return "pw-play" if shutil.which("pw-play") else "aplay"


def play(path: Path, cfg: Config) -> bool:
    """Play a WAV file through the configured player."""
    player = resolve_player(cfg)
    try:
        result = subprocess.run([player, str(path)])
    except OSError as exc:
        log.error("Playback with %s failed: %s", player, exc)
        return False
    if result.returncode != 0:
        log.error("%s exited with code %d", player, result.returncode)
        return False
    return True
