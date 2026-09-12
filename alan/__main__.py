"""Entry point: ``python -m alan``."""

from __future__ import annotations

import logging
import signal
import sys
import threading
from types import FrameType
from typing import Optional

from .config import Config
from .face import run_face
from .pipeline import ai_worker
from .state import AssistantState


def main() -> None:
    # Never crash on the non-ASCII prompt glyphs under a non-UTF-8 locale.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")

    cfg = Config.from_env()
    logging.basicConfig(
        level=getattr(logging, cfg.log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    print("=== STARTING ALAN OS ===")

    st = AssistantState()

    def _handle_signal(signum: int, frame: Optional[FrameType]) -> None:
        logging.getLogger("alan").info("Received signal %d, shutting down.", signum)
        st.stop()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    worker = threading.Thread(target=ai_worker, args=(cfg, st), name="ai-worker", daemon=True)
    worker.start()

    run_face(cfg, st)

    print("\n[!] System Shut Down.")


if __name__ == "__main__":
    main()
