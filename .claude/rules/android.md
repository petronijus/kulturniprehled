---
paths:
  - "apps/mobile/android/**"
---
# Android (apps/mobile/android)

- The manifest must keep `ScheduledNotificationReceiver` and
  `ScheduledNotificationBootReceiver` (flutter_local_notifications does not
  merge them); `test/android_manifest_test.dart` pins them.
- `applicationId` and namespace `com.kulturniprehled.kp_mobile` are the
  installed app's identity; never rename them.
- Release signing reads `android/key.properties` (gitignored) and the
  keystore outside the repo; never commit or print either. The release
  certificate SHA-1 is registered in the Google OAuth client: a different
  key breaks Google sign-in (docs/release.md).
- R8 stays off (`isMinifyEnabled = false`): the notification plugin's Gson
  serialisation breaks under it.
- Toolchain: AGP 9.2.1, Kotlin 2.4.20, Gradle 9.4.1, JDK 25; verify a bump
  with `just build-android`, not with tests.
