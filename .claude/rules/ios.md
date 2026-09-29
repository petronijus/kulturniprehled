---
paths:
  - "apps/mobile/ios/**"
---
# iOS (apps/mobile/ios)

- Builds need macOS (the MacBook or the Proxmox MacOS VM); on Linux say the
  iOS lane was not run.
- CocoaPods, not Swift Package Manager (`flutter config
  --no-enable-swift-package-manager` per machine).
- `project.pbxproj`: prefer Xcode or an xcodeproj script to hand edits.
- `Info.plist`, `ExportOptions.plist` and the pbxproj carry placeholders
  (`YOUR_IOS_CLIENT_ID`, `YOURTEAMID`); `scripts/ios-inject-private.sh`
  swaps in the real values before a build and `--restore` puts the
  placeholders back. Never commit the real ones.
- TestFlight builds use manual signing (automatic signing from the CLI mints
  development certificates); see docs/release.md.
- `ITSAppUsesNonExemptEncryption = false` stays: standard HTTPS only.
