"""Shared, thread-safe assistant state."""

from __future__ import annotations

import threading
from enum import Enum


class State(Enum):
    """Visual/pipeline states of the assistant."""

    IDLE = "IDLE"
    LISTENING = "LISTENING"
    THINKING = "THINKING"
    SPEAKING = "SPEAKING"


class AssistantState:
    """Holds the current State behind a lock plus a shutdown event."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._state = State.IDLE
        self._shutdown = threading.Event()

    @property
    def state(self) -> State:
        with self._lock:
            return self._state

    @state.setter
    def state(self, value: State) -> None:
        with self._lock:
            self._state = value

    def stop(self) -> None:
        """Request shutdown of every loop."""
        self._shutdown.set()

    @property
    def running(self) -> bool:
        return not self._shutdown.is_set()

    def is_running(self) -> bool:
        return self.running

    def wait(self, timeout: float | None = None) -> bool:
        """Block until shutdown is requested or ``timeout`` elapses.

        Returns True if shutdown was requested.
        """
        return self._shutdown.wait(timeout)
