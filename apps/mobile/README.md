# `kp-mobile` — Kulturní Přehled mobile app

Flutter app targeting Android (primary) and iOS (full feature parity). See the
[top-level CLAUDE.md](../../CLAUDE.md) for project context and conventions.

## Status

Placeholder. The Flutter project is scaffolded during milestone M5
(Flutter foundation + auth + agenda). Run the commands below once Flutter is
installed locally.

## Prerequisites

- Flutter 3.x (`flutter --version`)
- Android Studio + Android SDK (primary test target)
- Xcode (iOS smoke testing)

## Scaffolding (run once when starting M5)

```bash
cd apps
flutter create \
  --org com.kulturniprehled \
  --project-name kp_mobile \
  --platforms=android,ios \
  --description "Kulturní Přehled — shared cultural-event tracker" \
  mobile
```

After scaffolding, replace this README with one describing the actual app
structure, the state-management approach (Riverpod), the local persistence
(drift), and how to run the integration tests.

## Planned package set

- `flutter_riverpod` — state management
- `go_router` — navigation
- `drift` + `sqlite3_flutter_libs` — local SQLite cache
- `dio` — HTTP client (with generated OpenAPI client on top)
- `google_sign_in` — Google OAuth login
- `flutter_secure_storage` — JWT and encryption keys
- `path_provider` — ticket file storage on device
- `table_calendar` — monthly calendar view
- `firebase_messaging` (Android) + native APNs bridge or `flutter_apns_only` (iOS)
- `cryptography` — AES-GCM encryption of cached tickets

## Testing

- Unit + widget tests: `flutter test`
- Integration tests: `flutter test integration_test`
- CI builds both `.apk` (Android, primary) and `.ipa` (iOS) from milestone M5
  onward.
