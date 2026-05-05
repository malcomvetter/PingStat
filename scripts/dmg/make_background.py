#!/usr/bin/env python3
"""Write a wide PNG for DMG window background (no third-party deps)."""
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


def write_light_background_with_arrow(
    path: str,
    width: int,
    height: int,
    bg_rgb: tuple[int, int, int],
    arrow_rgb: tuple[int, int, int],
) -> None:
    """Light fill plus a simple left→right arrow (shaft + head); Finder draws icons on top."""
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

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter 0
        fy = float(y) + 0.5
        for x in range(width):
            fx = float(x) + 0.5
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
            raw.extend(arrow_rgb if (in_shaft or in_head) else bg_rgb)

    compressed = zlib.compress(bytes(raw), 9)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", compressed) + _chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "background.png"
    # Soft neutral light field; muted arrow reads under Finder icons.
    write_light_background_with_arrow(out, 660, 420, (248, 249, 252), (88, 96, 112))


if __name__ == "__main__":
    main()
