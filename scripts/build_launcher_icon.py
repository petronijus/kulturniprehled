#!/usr/bin/env python3
"""Render the Kulturní Přehled KP mark into Android mipmaps, iOS appiconset,
and in-app PNG.

Source: `apps/mobile/assets/brand/kp_logo.svg` exported from Figma. We
rasterise once at 1024 px (white background, centred with safe-zone padding)
and downsample to each Android launcher density, every iOS AppIcon slot,
and to a transparent in-app PNG used by the agenda top bar.
"""

from __future__ import annotations

from pathlib import Path

import cairosvg
from PIL import Image

REPO = Path(__file__).resolve().parents[1]
SVG = REPO / "apps/mobile/assets/brand/kp_logo.svg"
BRAND = REPO / "apps/mobile/assets/brand"
ANDROID_RES = REPO / "apps/mobile/android/app/src/main/res"
IOS_APPICON = REPO / "apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset"

MIPMAPS = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# Notification status-bar icon. Android renders the small icon as a
# monochrome silhouette: any non-transparent pixel becomes the channel's
# accent colour (white on dark, black on light). So we ship a flat white
# version of the KP mark on a transparent background, sized per density.
NOTIFICATION_ICONS = {
    "drawable-mdpi": 24,
    "drawable-hdpi": 36,
    "drawable-xhdpi": 48,
    "drawable-xxhdpi": 72,
    "drawable-xxxhdpi": 96,
}

# iOS AppIcon.appiconset slot → pixel size. Filenames must match the existing
# Contents.json shipped with the Flutter template.
IOS_ICONS = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
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


def notification_master() -> Image.Image:
    """Square transparent-bg render of the KP mark for the status-bar
    notification icon. Android takes any non-transparent pixel as the
    silhouette mask, so the source colour doesn't matter — only the
    alpha channel of the KP letters does. We pad to a square canvas
    with the mark sized at 78 % so the icon doesn't crowd the
    status-bar edge.
    """
    size = CANVAS
    svg_w, svg_h = 89.3745, 74.111
    mark_h = int(size * 0.78)
    mark_w = int(mark_h * svg_w / svg_h)
    mark = render_svg(mark_w, mark_h)
    canvas = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    canvas.paste(mark, ((size - mark_w) // 2, (size - mark_h) // 2), mark)
    return canvas


def main() -> None:
    master = launcher_master()
    master.save(BRAND / "launcher_master.png")
    for folder, px in MIPMAPS.items():
        target = ANDROID_RES / folder / "ic_launcher.png"
        master.resize((px, px), Image.LANCZOS).save(target)
        print(f"android:  {target.relative_to(REPO)} ({px}x{px})")

    # iOS rejects any alpha channel on the 1024 marketing icon and prefers
    # opaque RGB for all slots — flatten once and reuse.
    master_rgb = master.convert("RGB")
    for filename, px in IOS_ICONS.items():
        target = IOS_APPICON / filename
        master_rgb.resize((px, px), Image.LANCZOS).save(target)
        print(f"ios:      {target.relative_to(REPO)} ({px}x{px})")

    inapp = in_app_mark()
    inapp_path = BRAND / "kp_logo.png"
    inapp.save(inapp_path)
    print(f"in-app:   {inapp_path.relative_to(REPO)} ({inapp.width}x{inapp.height})")

    notif = notification_master()
    for folder, px in NOTIFICATION_ICONS.items():
        target = ANDROID_RES / folder / "ic_stat_notify.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        notif.resize((px, px), Image.LANCZOS).save(target)
        print(f"notif:    {target.relative_to(REPO)} ({px}x{px})")


if __name__ == "__main__":
    main()
