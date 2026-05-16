#!/usr/bin/env python3
"""Render the Kulturní Přehled KP mark into Android mipmaps + in-app PNG.

Source: `apps/mobile/assets/brand/kp_logo.svg` exported from Figma. We
rasterise once at 1024 px (white background, centred with safe-zone padding)
and downsample to each Android launcher density and to a transparent
in-app PNG used by the agenda top bar.
"""

from __future__ import annotations

from pathlib import Path

import cairosvg
from PIL import Image

REPO = Path(__file__).resolve().parents[1]
SVG = REPO / "apps/mobile/assets/brand/kp_logo.svg"
BRAND = REPO / "apps/mobile/assets/brand"
ANDROID_RES = REPO / "apps/mobile/android/app/src/main/res"

MIPMAPS = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

CANVAS = 1024  # master render size
MARK_FRAC = 0.62  # the KP mark occupies ~62% of the canvas (safe zone for
# round/squircle Android launcher masks)
IN_APP_HEIGHT = 1024  # px tall transparent PNG for the top bar (downscaled at runtime)


def render_svg(target_w: int, target_h: int) -> Image.Image:
    png_bytes = cairosvg.svg2png(
        url=str(SVG),
        output_width=target_w,
        output_height=target_h,
    )
    from io import BytesIO

    return Image.open(BytesIO(png_bytes)).convert("RGBA")


def launcher_master() -> Image.Image:
    """Composite the KP mark centred on a white background."""
    mark_h = int(CANVAS * MARK_FRAC)
    # Match the SVG's intrinsic aspect ratio so the K doesn't squash.
    svg_w, svg_h = 89.3745, 74.111  # from the SVG viewBox
    mark_w = int(mark_h * svg_w / svg_h)

    mark = render_svg(mark_w, mark_h)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (255, 255, 255, 255))
    x = (CANVAS - mark_w) // 2
    y = (CANVAS - mark_h) // 2
    canvas.paste(mark, (x, y), mark)
    return canvas


def in_app_mark() -> Image.Image:
    """Transparent-background render of the mark at IN_APP_HEIGHT px tall."""
    svg_w, svg_h = 89.3745, 74.111
    w = int(IN_APP_HEIGHT * svg_w / svg_h)
    return render_svg(w, IN_APP_HEIGHT)


def main() -> None:
    master = launcher_master()
    master.save(BRAND / "launcher_master.png")
    for folder, px in MIPMAPS.items():
        target = ANDROID_RES / folder / "ic_launcher.png"
        master.resize((px, px), Image.LANCZOS).save(target)
        print(f"launcher: {target.relative_to(REPO)} ({px}x{px})")

    inapp = in_app_mark()
    inapp_path = BRAND / "kp_logo.png"
    inapp.save(inapp_path)
    print(f"in-app:   {inapp_path.relative_to(REPO)} ({inapp.width}x{inapp.height})")


if __name__ == "__main__":
    main()
