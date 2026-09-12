"""Runtime configuration loaded from environment variables and ``config.env``."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

REPO_DIR: Path = Path(__file__).resolve().parent.parent
CONFIG_ENV_PATH: Path = REPO_DIR / "config.env"

DEFAULT_SYSTEM_PROMPT = (
    "You are Alan, a helpful, concise AI assistant. Keep answers under 2 sentences."
)


def load_env_file(path: Path) -> None:
    """Load KEY=VALUE lines from ``path`` into os.environ without overriding.

    Blank lines and ``#`` comments are skipped, an optional ``export`` prefix is
    ignored, and matching surrounding single or double quotes are stripped.
    """
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key.startswith("export "):
            key = key[len("export "):].strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if key:
            os.environ.setdefault(key, value)


def _env_str(name: str, default: str) -> str:
    return os.environ.get(name, default)


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from None


@dataclass(frozen=True)
class Config:
    """Immutable assistant settings. Defaults preserve the original behaviour."""

    audio_input: str = "auto"
    record_seconds: int = 5
    sample_rate: int = 44100
    audio_player: str = "auto"
    whisper_url: str = "http://localhost:8000/v1/audio/transcriptions"
    whisper_model: str = "tiny.en"
    ollama_url: str = "http://localhost:11434"
    llm_model: str = "qwen2.5:0.5b"
    system_prompt: str = DEFAULT_SYSTEM_PROMPT
    piper_voice: str = "en_GB-alan-medium"
    screen_width: int = 480
    screen_height: int = 320
    sdl_fbdev: str = "/dev/fb0"
    sdl_videodriver: str = ""
    fps: int = 30
    show_cpu_temp: bool = True
    log_level: str = "INFO"
    repo_dir: Path = field(default=REPO_DIR)

    @classmethod
    def from_env(cls) -> "Config":
        """Build a Config from ``<repo>/config.env`` (if present) and os.environ."""
        load_env_file(CONFIG_ENV_PATH)
        return cls(
            audio_input=_env_str("AUDIO_INPUT", "auto").strip() or "auto",
            record_seconds=_env_int("RECORD_SECONDS", 5),
            sample_rate=_env_int("SAMPLE_RATE", 44100),
            audio_player=_env_str("AUDIO_PLAYER", "auto").strip() or "auto",
            whisper_url=_env_str(
                "WHISPER_URL", "http://localhost:8000/v1/audio/transcriptions"
            ),
            whisper_model=_env_str("WHISPER_MODEL", "tiny.en"),
            ollama_url=_env_str("OLLAMA_URL", "http://localhost:11434"),
            llm_model=_env_str("LLM_MODEL", "qwen2.5:0.5b"),
            system_prompt=_env_str("SYSTEM_PROMPT", DEFAULT_SYSTEM_PROMPT),
            piper_voice=_env_str("PIPER_VOICE", "en_GB-alan-medium"),
            screen_width=_env_int("SCREEN_WIDTH", 480),
            screen_height=_env_int("SCREEN_HEIGHT", 320),
            sdl_fbdev=_env_str("SDL_FBDEV", "/dev/fb0"),
            sdl_videodriver=_env_str("SDL_VIDEODRIVER", "").strip(),
            fps=_env_int("FPS", 30),
            show_cpu_temp=_env_str("SHOW_CPU_TEMP", "1").strip() == "1",
            log_level=_env_str("LOG_LEVEL", "INFO").strip().upper() or "INFO",
            repo_dir=REPO_DIR,
        )

    @property
    def models_dir(self) -> Path:
        """Directory holding the Piper voice files."""
        return self.repo_dir / "models"

    @property
    def piper_model_path(self) -> Path:
        """Path to ``models/<PIPER_VOICE>.onnx``."""
        return self.models_dir / f"{self.piper_voice}.onnx"

    @property
    def ollama_generate_url(self) -> str:
        """Full Ollama generate endpoint."""
        return self.ollama_url.rstrip("/") + "/api/generate"
