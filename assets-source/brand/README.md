# Brand asset masters

User-authored master files for the Kulturní Přehled mobile app.

**Contract:**

- User drops master PNGs here. These are the source of truth.
- Claude reads from here, resizes into the per-platform/per-density
  variants required, and writes them into the right places under
  `apps/mobile/`.
- Claude never generates or modifies any file in this folder.
- Masters are tracked in git so the repo carries the originals — if a
  density needs to be regenerated, no Figma round-trip is needed.

## Files

| Master                  | Use                                           | Size       | Background  |
| ----------------------- | --------------------------------------------- | ---------- | ----------- |
| `kp_logo_master.png`    | In-app Kp mark, top of every screen           | 1024 px tall, free width | transparent |
| `kp_launcher_master.png`| Launcher icon — Android home + iOS home       | 1024 × 1024 | **opaque** (iOS rejects alpha). Kp in ~62% safe zone (round/squircle masks). |
| `kp_notif_master.png`   | Android notification status-bar icon          | 1024 × 1024 | transparent. Kp filled black at ~78% of canvas (Android renders any non-transparent pixel as monochrome silhouette). |

## Where Claude places the resized variants

| Master                   | Output targets                                                                                                                                                                  |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kp_logo_master.png`     | `apps/mobile/assets/brand/kp_logo.png` (single file, used at runtime).                                                                                                          |
| `kp_launcher_master.png` | Android: `apps/mobile/android/app/src/main/res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` (48 / 72 / 96 / 144 / 192 px). iOS: `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png` (20→1024 in @1x/@2x/@3x scales — see `Contents.json`). |
| `kp_notif_master.png`    | `apps/mobile/android/app/src/main/res/drawable-{m,h,xh,xxh,xxxh}dpi/ic_stat_notify.png` (24 / 36 / 48 / 72 / 96 px). iOS has no equivalent — notifications use the event cover. |

## How Claude resizes

Pillow (Python) — `Image.open(master).resize((px, px), Image.LANCZOS)`.
For PNGs that need optimization: `optimize=True`.
