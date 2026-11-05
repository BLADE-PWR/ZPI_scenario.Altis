#!/usr/bin/env python3
"""
Frame-number bar: decode it from a captured frame, and strip it before detection.

Nominal layout (what description.ext draws, in screen pixels):
  squares of SIZE x SIZE px in one row starting at (X0, Y0)
  square 0 = white sentinel, square 1 = black sentinel,
  squares 2..13 = bits 0..11 of diag_frameNo, LSB first (white = 1).

The bar is found by its sentinel pair rather than read at fixed offsets, so a
capture that starts a few pixels off (window borders, a cropped region) or at
another scale still decodes: the origin and the square size both come from the
white/black pair. Everything fails safe - a missing pair returns None.

12 bits wrap every 4096 frames (68 s at 60 fps). That is only ever used to say
which recent frame a captured image is; the telemetry record carries the frame
number in full.

Works with numpy arrays as returned by dxcam / mss / OpenCV (H x W x 3, uint8).
Channel order does not matter (the bar is pure black/white).
"""
from __future__ import annotations

import numpy as np

X0, Y0, SIZE, NBITS = 0, 0, 4, 12
N_SQUARES = NBITS + 2
MIN_SIZE, MAX_SIZE = 2, 16          # square sizes the locator accepts
SEARCH = 24                         # how far from the corner the bar may start
WHITE, BLACK = 200, 55              # sentinel levels (a bar square is pure 0 or 255)

Bar = tuple[int, int, int]          # x0, y0, square size


def _grey(img: np.ndarray) -> np.ndarray:
    return img.mean(axis=2) if img.ndim == 3 else img.astype(float)


def _square_level(grey: np.ndarray, bar: Bar, k: int) -> float:
    """Mean brightness of the middle of square k (robust to sub-pixel offsets)."""
    x0, y0, size = bar
    half = max(1, size // 4)        # inner 2x2 of a 4 px square, 4x4 of an 8 px one
    cx = x0 + size * k + size // 2
    cy = y0 + size // 2
    return float(grey[cy - half:cy + half, cx - half:cx + half].mean())


def locate(img: np.ndarray) -> Bar | None:
    """Find the bar from its sentinel pair: (x0, y0, square size), or None."""
    grey = _grey(img[:SEARCH + MAX_SIZE, :SEARCH + MAX_SIZE * N_SQUARES])
    h, w = grey.shape
    for y in range(min(SEARCH, h - MIN_SIZE)):
        row = grey[y]
        bright = np.flatnonzero(row >= WHITE)
        if bright.size == 0 or bright[0] > SEARCH:
            continue
        x = int(bright[0])
        size = 1
        while x + size < w and row[x + size] >= WHITE:
            size += 1
        if not (MIN_SIZE <= size <= MAX_SIZE):
            continue
        bar = (x, y, size)
        # the black sentinel next to it, and the bar's own height, confirm the fit
        if _square_level(grey, bar, 1) > BLACK:
            continue
        if x + size * N_SQUARES > w or y + size >= h:
            continue
        if grey[y + size, x + size // 2] >= WHITE:
            continue                # taller than one square: not the bar
        return bar
    return None


def decode(img: np.ndarray, threshold: float = 128.0, bar: Bar | None = None) -> int | None:
    """Return the frame number encoded in the bar, or None if it is not there."""
    if bar is None:
        bar = locate(img)
        if bar is None:
            return None             # no bar (wrong crop, or a fade in progress)
    grey = _grey(img)
    value = 0
    for i in range(NBITS):
        if _square_level(grey, bar, 2 + i) >= threshold:
            value |= 1 << i
    return value


def strip(img: np.ndarray, bar: Bar | None = None) -> np.ndarray:
    """Return a copy with the bar region blacked out, ready for the detector."""
    x0, y0, size = bar or locate(img) or (X0, Y0, SIZE)
    out = img.copy()
    out[:y0 + size + 2, :x0 + size * N_SQUARES + 2] = 0
    return out


def render(frame: int, width: int = 1920, height: int = 1080, bar: Bar = (X0, Y0, SIZE)) -> np.ndarray:
    """Draw the bar exactly like the game does (used for tests)."""
    x0, y0, size = bar
    img = np.full((height, width, 3), 90, np.uint8)  # grey "terrain"

    def fill(k: int, white: bool):
        x = x0 + size * k
        img[y0:y0 + size, x:x + size] = 255 if white else 0

    fill(0, True)
    fill(1, False)
    for i in range(NBITS):
        fill(2 + i, bool((frame >> i) & 1))
    return img


if __name__ == "__main__":
    rng = np.random.default_rng(0)
    frames = [0, 1, 2731, 2**NBITS - 1, *rng.integers(0, 2**NBITS, 200)]

    for f in frames:                                 # nominal layout, JPEG-ish noise
        img = render(int(f))
        img = np.clip(img.astype(int) + rng.integers(-20, 21, img.shape), 0, 255).astype(np.uint8)
        assert decode(img) == int(f), f

    for bar in [(0, 0, 4), (3, 1, 4), (17, 9, 4), (0, 0, 8), (6, 2, 16), (1, 0, 2)]:
        assert locate(render(1, bar=bar)) == bar, bar  # offset and scale are read off the bar
        for f in frames[:20]:
            assert decode(render(int(f), bar=bar)) == int(f), (bar, f)

    assert decode(np.full((1080, 1920, 3), 90, np.uint8)) is None    # plain terrain
    assert decode(np.full((1080, 1920, 3), 255, np.uint8)) is None   # no black sentinel
    assert locate(render(1, bar=(40, 0, 4))) is None                 # too far from the corner

    stripped = strip(render(5, bar=(3, 1, 4)))
    assert stripped[:1 + 4 + 2, :3 + 4 * N_SQUARES + 2].max() == 0
    assert decode(stripped) is None
    print("frame_code self-test passed")
