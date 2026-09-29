---
paths:
  - "apps/mobile/lib/**"
  - "apps/mobile/test/**"
---
# Flutter app (apps/mobile/lib)

- Android is the primary target, iOS keeps full parity: no Android-only
  feature, no Cupertino-only widget, every package must work on both.
- Offline first: UI writes go through the outbox (`features/outbox`), never
  straight to the API. The client never writes `version` (docs/sync.md).
- Riverpod fakes in tests: subclass and `overrideWith((ref) => fake)`.
- `dart format`, `flutter_lints` strict, no `dynamic`, no `late` unless
  unavoidable; package imports only.
- Background isolates (WorkManager / BGTaskScheduler) do not run `main()`:
  anything they need (Czech locale data, plugin init, auth) is initialised
  on their own path. Errors there are logged, never swallowed.
- Notifications: reminders use `AndroidScheduleMode.alarmClock`;
  `reschedule()` stays single-flight. A change here needs a check on a real,
  locked Android phone, not just `flutter test`.
- Auth: refresh rotation is shared across isolates; never clear credentials
  on a transient failure.
- `database.g.dart` is generated: change the drift tables, then
  `dart run build_runner build`.
- UI strings are English.
