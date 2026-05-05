#!/usr/bin/env python3
"""Write a wide PNG for DMG window background (no third-party deps).

Rasterizes a simple arrow with supersampled anti-aliasing. Output dimensions must
match create-dmg ``--window-size`` (660×420 px in ``package-dmg.sh``); Finder maps
background pixels to that window—doubling width/height hides or misplaces art.

Edge softness comes from 6×6 supersampling within each output pixel.
"""
from __future__ import annotations

import struct
import sys
import zlib


def _chunk(chunk_type: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)


def _point_in_triangle(
    px: float,
    py: float,
    ax: float,
    ay: float,
    bx: float,
    by: float,
    cx: float,
    cy: float,
) -> bool:
    def sign(sx: float, sy: float, p1x: float, p1y: float, p2x: float, p2y: float) -> float:
        return (sx - p2x) * (p1y - p2y) - (p1x - p2x) * (sy - p2y)

    d1 = sign(px, py, ax, ay, bx, by)
    d2 = sign(px, py, bx, by, cx, cy)
    d3 = sign(px, py, cx, cy, ax, ay)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def _point_inside_arrow(fx: float, fy: float, width: int, height: int) -> bool:
    """True if (fx, fy) lies inside the arrow (shaft + head), float pixel coords."""
    cx = width * 0.5
    cy = height * 0.48
    arrow_len = min(width * 0.24, height * 0.52)
    half_thick = max(5.0, height * 0.016)
    head_len = arrow_len * 0.24
    shaft_len = arrow_len - head_len
    x0 = cx - arrow_len * 0.5
    x_shaft_end = x0 + shaft_len
    x_tip = x0 + arrow_len
    head_half = head_len * 0.85

    in_shaft = (
        x0 <= fx <= x_shaft_end
        and (cy - half_thick) <= fy <= (cy + half_thick)
    )
    in_head = _point_in_triangle(
        fx,
        fy,
        x_tip,
        cy,
        x_shaft_end,
        cy + head_half,
        x_shaft_end,
        cy - head_half,
    )
    return in_shaft or in_head


def _blend_rgb(
    bg: tuple[int, int, int],
    fg: tuple[int, int, int],
    alpha: float,
) -> tuple[int, int, int]:
    """Blend fg over bg (simple gamma-ish blend in 8-bit space)."""
    a = max(0.0, min(1.0, alpha))
    return (
        int(round(bg[0] * (1.0 - a) + fg[0] * a)),
        int(round(bg[1] * (1.0 - a) + fg[1] * a)),
        int(round(bg[2] * (1.0 - a) + fg[2] * a)),
    )


def write_light_background_with_arrow(
    path: str,
    width: int,
    height: int,
    bg_rgb: tuple[int, int, int],
    arrow_rgb: tuple[int, int, int],
    *,
    supersample: int = 6,
) -> None:
    """Light fill plus a simple left→right arrow (shaft + head); Finder draws icons on top."""
    if supersample < 1:
        supersample = 1

    raw = bytearray()
    inv_ss = 1.0 / supersample
    samples = supersample * supersample

    for y in range(height):
        raw.append(0)  # filter 0
        for x in range(width):
            acc = 0.0
            for j in range(supersample):
                sy = y + (j + 0.5) * inv_ss
                for i in range(supersample):
                    sx = x + (i + 0.5) * inv_ss
                    if _point_inside_arrow(sx, sy, width, height):
                        acc += 1.0
            alpha = acc / samples
            rgb = _blend_rgb(bg_rgb, arrow_rgb, alpha)
            raw.extend(rgb)

    compressed = zlib.compress(bytes(raw), 9)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", compressed) + _chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


# App-icon “blazing” teal: NSColor(calibratedRed: 0.15, green: 0.88, blue: 0.82) → sRGB for PNG
# (same source as scripts/GenerateAppIcon.swift `blazingTeal()`).
ARROW_RGB_SRGB = (31, 228, 218)


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "background.png"
    # Must match package-dmg.sh --window-size 660 420 (Finder aligns background to window).
    write_light_background_with_arrow(out, 660, 420, (248, 249, 252), ARROW_RGB_SRGB)


if __name__ == "__main__":
    main()
