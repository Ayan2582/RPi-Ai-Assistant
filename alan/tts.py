"""Text-to-speech via the Piper CLI installed in the venv."""

from __future__ import annotations

import logging
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

from .config import Config

log = logging.getLogger(__name__)

Player = Callable[[Path, Config], object]


def find_piper() -> str | None:
    """Locate piper next to the running interpreter (venv), else on PATH."""
    candidate = Path(sys.executable).parent / "piper"
    if candidate.is_file():
        return str(candidate)
    return shutil.which("piper")


def speak(text: str, cfg: Config, player: Player) -> None:
    """Synthesize ``text`` to a temporary WAV and play it with ``player``."""
    if not text:
        return
    model = cfg.piper_model_path
    if not model.is_file():
        log.error(
            "Piper voice model not found at %s. Run scripts/install.sh to download it.",
            model,
        )
        return
    piper = find_piper()
    if piper is None:
        log.error("piper executable not found. Run scripts/install.sh to install it.")
        return

    with tempfile.TemporaryDirectory(prefix="alan-tts-") as tmp:
        wav = Path(tmp) / "output.wav"
        try:
            result = subprocess.run(
                [piper, "--model", str(model), "--output_file", str(wav)],
                input=text,
                text=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
        except OSError as exc:
            log.error("Failed to run piper: %s", exc)
            return
        if result.returncode != 0 or not wav.is_file():
            log.error(
                "piper failed (exit %d): %s", result.returncode, result.stderr.strip()
            )
            return
        player(wav, cfg)
