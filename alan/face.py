"""Pygame renderer for Alan's pixel face (runs on the main thread)."""

from __future__ import annotations

import logging
import os
import time
from pathlib import Path
from typing import Callable, Dict, Optional

import pygame

from .config import Config
from .state import AssistantState, State

log = logging.getLogger(__name__)

BLACK = (0, 0, 0)
GREEN = (0, 255, 0)

EYE_WIDTH, EYE_HEIGHT = 40, 40
THERMAL_PATH = Path("/sys/class/thermal/thermal_zone0/temp")
TEMP_REFRESH_SECONDS = 1.0
TEMP_FONT_SIZE = 22
TEMP_MARGIN = 6

DrawFn = Callable[[pygame.Surface, int, int, int], None]


def _eyes(cx: int, cy: int) -> tuple[pygame.Rect, pygame.Rect]:
    left = pygame.Rect(cx - 100, cy - 60, EYE_WIDTH, EYE_HEIGHT)
    right = pygame.Rect(cx + 60, cy - 60, EYE_WIDTH, EYE_HEIGHT)
    return left, right


def draw_idle(screen: pygame.Surface, cx: int, cy: int, frame_count: int) -> None:
    left_eye, right_eye = _eyes(cx, cy)
    pygame.draw.rect(screen, GREEN, left_eye)
    pygame.draw.rect(screen, GREEN, right_eye)
    # Smile: wide bar plus raised edges
    pygame.draw.rect(screen, GREEN, (cx - 60, cy + 40, 120, 20))
    pygame.draw.rect(screen, GREEN, (cx - 80, cy + 20, 20, 40))
    pygame.draw.rect(screen, GREEN, (cx + 60, cy + 20, 20, 40))


def draw_listening(screen: pygame.Surface, cx: int, cy: int, frame_count: int) -> None:
    left_eye, _ = _eyes(cx, cy)
    # One eye closed (wink)
    pygame.draw.rect(screen, GREEN, left_eye)
    pygame.draw.rect(screen, GREEN, (cx + 60, cy - 45, EYE_WIDTH, 10))
    # Small 'o' mouth
    pygame.draw.rect(screen, GREEN, (cx - 20, cy + 30, 40, 40), 10)


def draw_thinking(screen: pygame.Surface, cx: int, cy: int, frame_count: int) -> None:
    left_eye, right_eye = _eyes(cx, cy)
    # Blink every 15 frames
    if (frame_count // 15) % 2 == 0:
        pygame.draw.rect(screen, GREEN, left_eye)
        pygame.draw.rect(screen, GREEN, right_eye)
    else:
        pygame.draw.rect(screen, GREEN, (cx - 100, cy - 45, EYE_WIDTH, 10))
        pygame.draw.rect(screen, GREEN, (cx + 60, cy - 45, EYE_WIDTH, 10))
    # Straight mouth
    pygame.draw.rect(screen, GREEN, (cx - 40, cy + 40, 80, 10))


def draw_speaking(screen: pygame.Surface, cx: int, cy: int, frame_count: int) -> None:
    left_eye, right_eye = _eyes(cx, cy)
    pygame.draw.rect(screen, GREEN, left_eye)
    pygame.draw.rect(screen, GREEN, right_eye)
    # Mouth height oscillates to simulate talking
    mouth_height = 10 + (abs((frame_count % 20) - 10) * 4)
    pygame.draw.rect(screen, GREEN, (cx - 50, cy + 40 - (mouth_height // 2), 100, mouth_height))


DRAW_FUNCTIONS: Dict[State, DrawFn] = {
    State.IDLE: draw_idle,
    State.LISTENING: draw_listening,
    State.THINKING: draw_thinking,
    State.SPEAKING: draw_speaking,
}


def read_cpu_temp() -> Optional[float]:
    """Return the CPU temperature in degrees Celsius, or None if unavailable."""
    try:
        return int(THERMAL_PATH.read_text().strip()) / 1000.0
    except (OSError, ValueError):
        return None


def run_face(cfg: Config, st: AssistantState) -> None:
    """Open the display and draw the face until shutdown is requested."""
    os.environ["SDL_FBDEV"] = cfg.sdl_fbdev
    if cfg.sdl_videodriver:
        os.environ["SDL_VIDEODRIVER"] = cfg.sdl_videodriver
    elif os.environ.get("SDL_VIDEODRIVER", None) == "":
        # An exported-but-empty value would confuse SDL's driver selection.
        del os.environ["SDL_VIDEODRIVER"]

    pygame.init()
    try:
        pygame.mouse.set_visible(False)
        width, height = cfg.screen_width, cfg.screen_height
        try:
            screen = pygame.display.set_mode((width, height))
        except pygame.error as exc:
            log.error(
                "Pygame failed to open the display (%s). Ensure you have permissions for %s.",
                exc, cfg.sdl_fbdev,
            )
            st.stop()
            return

        font: Optional[pygame.font.Font] = None
        if cfg.show_cpu_temp:
            try:
                font = pygame.font.Font(None, TEMP_FONT_SIZE)
            except Exception:
                log.warning("Font unavailable; CPU temperature readout disabled.")

        clock = pygame.time.Clock()
        frame_count = 0
        temp_surface: Optional[pygame.Surface] = None
        next_temp_read = 0.0
        cx, cy = width // 2, height // 2

        while st.running:
            screen.fill(BLACK)
            DRAW_FUNCTIONS[st.state](screen, cx, cy, frame_count)

            if font is not None:
                now = time.monotonic()
                if now >= next_temp_read:
                    next_temp_read = now + TEMP_REFRESH_SECONDS
                    temp = read_cpu_temp()
                    temp_surface = (
                        font.render(f"CPU: {temp:.1f}°C", True, GREEN)
                        if temp is not None
                        else None
                    )
                if temp_surface is not None:
                    rect = temp_surface.get_rect(topright=(width - TEMP_MARGIN, TEMP_MARGIN))
                    screen.blit(temp_surface, rect)

            pygame.display.flip()

            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    st.stop()

            frame_count += 1
            clock.tick(cfg.fps)
    finally:
        pygame.quit()
