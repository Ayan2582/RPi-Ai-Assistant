"""Background worker: ENTER -> listen -> think -> speak."""

from __future__ import annotations

import dataclasses
import logging
import tempfile
from pathlib import Path

from . import audio, llm, stt, tts
from .config import Config
from .state import AssistantState, State

log = logging.getLogger(__name__)

STARTUP_DELAY_SECONDS = 2.0
PROMPT = "\n[▶] Press ENTER to talk to Alan (or type 'quit' to exit)..."


def ai_worker(cfg: Config, st: AssistantState) -> None:
    """Run the voice pipeline loop until shutdown is requested."""
    # Give pygame a moment to open the screen before the console prompt.
    if st.wait(STARTUP_DELAY_SECONDS):
        return

    cfg = dataclasses.replace(cfg, audio_input=audio.detect_input_device(cfg.audio_input))

    while st.running:
        try:
            line = input(PROMPT)
        except EOFError:
            log.warning("stdin is closed; ENTER trigger disabled. Waiting for shutdown.")
            st.wait()
            return

        if not st.running:
            return
        if line.strip().lower() == "quit":
            st.stop()
            return

        try:
            with tempfile.TemporaryDirectory(prefix="alan-") as tmp:
                in_file = Path(tmp) / "input.wav"

                st.state = State.LISTENING
                if not audio.record(in_file, cfg):
                    continue

                st.state = State.THINKING
                user_text = stt.transcribe(in_file, cfg)
                if not user_text:
                    log.info("No speech recognised.")
                    continue
                print(f"\n[USER] {user_text}")
                reply = llm.think(user_text, cfg)

                st.state = State.SPEAKING
                if reply:
                    print(f"\n[ALAN] {reply}")
                    tts.speak(reply, cfg, audio.play)
        except Exception:
            log.exception("Unexpected error in the AI pipeline")
        finally:
            st.state = State.IDLE
