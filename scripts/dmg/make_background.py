#!/usr/bin/env python3
"""Write a wide PNG for DMG window background (no third-party deps)."""
from __future__ import annotations

import struct
import sys
import zlib


def _chunk(chunk_type: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)


def write_split_panel_png(
    path: str,
    width: int,
    height: int,
    left_rgb: tuple[int, int, int],
    right_rgb: tuple[int, int, int],
) -> None:
    """Two-tone panel (classic install-DMG look); Finder draws icons on top."""
    mid = width // 2
    raw = bytearray()
    for _y in range(height):
        raw.append(0)  # filter 0 per scanline
        for x in range(width):
            raw.extend(left_rgb if x < mid else right_rgb)
    compressed = zlib.compress(bytes(raw), 9)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", compressed) + _chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "background.png"
    # Lighter left / darker right so “app | Applications” zones read at a glance.
    write_split_panel_png(out, 660, 420, (72, 82, 98), (38, 46, 58))


if __name__ == "__main__":
    main()
