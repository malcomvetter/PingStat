#!/usr/bin/env python3
"""Create a layout DMG (background PNG + icon positions + Applications link) without AppleScript.

Uses dmgbuild (https://github.com/dmgbuild/dmgbuild) so CI and headless environments get the same
visual treatment as local ``create-dmg`` + Finder, without ``osascript``.
"""
from __future__ import annotations

import argparse
import os
import sys


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--app", required=True, help="Path to PingStat.app")
    ap.add_argument("--output", required=True, help="Output .dmg path")
    ap.add_argument("--volume-name", required=True, help="Mounted volume title")
    ap.add_argument("--background", required=True, help="Background PNG path")
    args = ap.parse_args()

    try:
        import dmgbuild
    except ImportError:
        print("error: dmgbuild not installed (pip3 install dmgbuild)", file=sys.stderr)
        sys.exit(2)

    app_path = os.path.abspath(args.app)
    if not os.path.isdir(app_path):
        print(f"error: app bundle not found: {app_path}", file=sys.stderr)
        sys.exit(1)

    app_name = os.path.basename(app_path.rstrip("/"))
    bg_path = os.path.abspath(args.background)
    out_path = os.path.abspath(args.output)

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    if os.path.isfile(out_path):
        os.remove(out_path)

    # Match scripts/package-dmg.sh create-dmg window / icon layout.
    settings: dict = {
        "files": [app_path],
        "symlinks": {"Applications": "/Applications"},
        "background": bg_path,
        "window_rect": ((200, 120), (660, 420)),
        "icon_size": 100.0,
        "text_size": 12.0,
        "format": "UDZO",
        "hide_extensions": [app_name],
        "icon_locations": {
            app_name: (150, 200),
            "Applications": (500, 200),
        },
        "show_toolbar": False,
        "show_status_bar": False,
        "show_tab_view": False,
        "show_pathbar": False,
        "show_sidebar": False,
    }

    dmgbuild.build_dmg(out_path, args.volume_name, settings=settings)


if __name__ == "__main__":
    main()
