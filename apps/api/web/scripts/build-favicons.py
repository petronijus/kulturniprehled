#!/usr/bin/env python3
"""Resize the launcher master into the planner's favicons.

Per `assets-source/brand/README.md` the masters are user-authored and never
modified here — this only downsizes `kp_launcher_master.png` (opaque, Kp inside
the safe zone) into the sizes a browser tab and an iOS home-screen shortcut
need. Re-run after the master changes:

    uv run --with pillow python scripts/build-favicons.py
"""

from __future__ import annotations

import pathlib

from PIL import Image

WEB = pathlib.Path(__file__).resolve().parent.parent
MASTER = WEB.parent.parent.parent / "assets-source" / "brand" / "kp_launcher_master.png"
OUT = WEB / "public"

# 32 px: browser tab. 180 px: iOS "Add to Home Screen". 192 px: Android/PWA.
SIZES = {
    "favicon-32.png": 32,
    "apple-touch-icon.png": 180,
    "favicon-192.png": 192,
}


def main() -> int:
    if not MASTER.is_file():
        raise SystemExit(f"master not found: {MASTER}")

    master = Image.open(MASTER).convert("RGBA")
    for name, size in SIZES.items():
        target = OUT / name
        master.resize((size, size), Image.LANCZOS).save(target, optimize=True)
        print(f"wrote {target.relative_to(WEB)} ({size}px)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
