import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

// Regression guard for the silent "no background notification" bug.
//
// `NotificationService.showNewEvent` formats the event date with the Czech
// locale: `DateFormat("EEEE d.M. 'v' HH:mm", 'cs')`. The background
// WorkManager / BGTask isolate never runs `main()`'s
// `initializeDateFormatting('cs')`, so that format threw
// `LocaleDataException: Locale data has not been initialized` in the
// background isolate — and `pullChanges` swallowed it, so the notification
// just never posted. The fix calls `initializeDateFormatting('cs')` on the
// notification path (`_ensurePluginReady`), which runs in every isolate.
//
// This pins the contract the bug violated: once 'cs' locale data is loaded,
// the exact pattern used by the notification formats to a Czech string
// without throwing.
void main() {
  test('Czech notification date format works once locale data is loaded', () async {
    await initializeDateFormatting('cs');

    final DateFormat fmt = DateFormat("EEEE d.M. 'v' HH:mm", 'cs');
    // 2026-11-12 is a Thursday — "čtvrtek" proves the 'cs' symbols loaded
    // (not an English fallback), and formatting not throwing is the actual
    // regression target.
    final String out = fmt.format(DateTime(2026, 11, 12, 20, 0));

    expect(out, contains('čtvrtek'));
    expect(out, contains('12.11.'));
    expect(out, contains('20:00'));
  });
}
