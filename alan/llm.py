"""Reply generation via the local Ollama API."""

from __future__ import annotations

import logging

import requests

from .config import Config

log = logging.getLogger(__name__)

TIMEOUT_SECONDS = 120
ERROR_REPLY = "Sorry, I had a system error."
_session = requests.Session()


def think(prompt: str, cfg: Config) -> str:
    """Ask the LLM for a reply to ``prompt``."""
    payload = {
        "model": cfg.llm_model,
        "system": cfg.system_prompt,
        "prompt": prompt,
        "stream": False,
    }
    try:
        response = _session.post(
            cfg.ollama_generate_url, json=payload, timeout=TIMEOUT_SECONDS
        )
        response.raise_for_status()
        return str(response.json().get("response", "")).strip()
    except Exception:
        log.exception("LLM request failed (%s, model %s)", cfg.ollama_generate_url, cfg.llm_model)
        return ERROR_REPLY
