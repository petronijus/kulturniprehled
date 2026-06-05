import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/notifications/notification_service.dart';

// Regression guard for the "every scheduled notification silently vanished"
// bug (live-reproduced 2026-06-05, root cause of the missed 2026-06-04
// concert reminder).
//
// The agenda stream emits once per drift transaction, so a single sync
// burst fired several overlapping `reschedule()` runs. Each run starts with
// `cancelAll()`, and the plugin's cancel path rebuilds the alarm
// PendingIntent from a bare intent with FLAG_UPDATE_CURRENT — stripping the
// payload off alarms a concurrent run had just scheduled. The alarm then
// fired with no extras and ScheduledNotificationReceiver dropped it:
// "Failed to parse a notification from Intent".
//
// The fix serializes `reschedule()` (single-flight, bursts coalesce to the
// newest rows), so cancelAll/zonedSchedule blocks can never interleave.
// These tests pin that contract at the plugin-call level.

/// Records the plugin calls `reschedule()` makes, with a tiny async delay
/// on each so unserialized concurrent runs WOULD interleave — the
/// assertions below would catch the original bug.
class _RecordingPlugin implements FlutterLocalNotificationsPlugin {
  final List<String> calls = <String>[];
  bool throwOnNextCancelAll = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #initialize) {
      calls.add('initialize');
      return Future<bool?>.value(true);
    }
    if (invocation.memberName == #cancelAll) {
      calls.add('cancelAll');
      if (throwOnNextCancelAll) {
        throwOnNextCancelAll = false;
        return Future<void>.error(StateError('simulated platform failure'));
      }
      return Future<void>.delayed(const Duration(milliseconds: 2));
    }
    if (invocation.memberName == #zonedSchedule) {
      calls.add('schedule:${invocation.positionalArguments[1]}');
      return Future<void>.delayed(const Duration(milliseconds: 2));
    }
    if (invocation.memberName == #resolvePlatformSpecificImplementation) {
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}

CachedEventRow _event({
  required String id,
  required String title,
  required DateTime startsAt,
  DateTime? departureAt,
}) {
  return CachedEventRow(
    id: id,
    workspaceId: 'ws-1',
    title: title,
    category: 'concert',
    startsAt: startsAt,
    status: 'planned',
    source: 'manual',
    departureAt: departureAt,
    version: 1,
    updatedAt: DateTime.now(),
    cachedAt: DateTime.now(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingPlugin plugin;
  late NotificationService service;

  setUp(() async {
    await initializeDateFormatting('cs');
    plugin = _RecordingPlugin();
    service = NotificationService(
      plugin,
      localTimezone: () async => 'Europe/Prague',
    );
  });

  List<String> schedulesAfterLastCancel() {
    final int lastCancel = plugin.calls.lastIndexOf('cancelAll');
    return plugin.calls
        .sublist(lastCancel + 1)
        .where((c) => c.startsWith('schedule:'))
        .toList();
  }

  test(
    'overlapping reschedule bursts serialize and coalesce to newest rows',
    () async {
      final DateTime tomorrow20 = DateTime.now()
          .add(const Duration(days: 1))
          .copyWith(hour: 20, minute: 0, second: 0, millisecond: 0);

      final List<CachedEventRow> first = <CachedEventRow>[
        _event(id: 'e1', title: 'Stale A', startsAt: tomorrow20),
      ];
      final List<CachedEventRow> second = <CachedEventRow>[
        _event(id: 'e2', title: 'Stale B', startsAt: tomorrow20),
      ];
      final List<CachedEventRow> third = <CachedEventRow>[
        _event(
          id: 'e3',
          title: 'Fresh C',
          startsAt: tomorrow20,
          departureAt: tomorrow20.subtract(const Duration(hours: 1)),
        ),
      ];

      // Fire a burst without awaiting — exactly what the agenda listener does
      // when one sync upserts several events.
      final Future<void> f1 = service.reschedule(first);
      final Future<void> f2 = service.reschedule(second);
      final Future<void> f3 = service.reschedule(third);
      await Future.wait(<Future<void>>[f1, f2, f3]);

      final List<String> cancels = plugin.calls
          .where((c) => c == 'cancelAll')
          .toList();
      // First run takes `first`; the burst behind it coalesces to `third`.
      expect(cancels, hasLength(2));

      // No cancelAll may ever land inside another run's schedule block —
      // i.e. between two cancelAlls there is always at least one schedule,
      // and the log never ends on a wipe.
      expect(plugin.calls.last, startsWith('schedule:'));
      final List<int> cancelIndexes = <int>[
        for (int i = 0; i < plugin.calls.length; i++)
          if (plugin.calls[i] == 'cancelAll') i,
      ];
      for (int n = 1; n < cancelIndexes.length; n++) {
        final List<String> between = plugin.calls.sublist(
          cancelIndexes[n - 1] + 1,
          cancelIndexes[n],
        );
        expect(
          between.any((c) => c.startsWith('schedule:')),
          isTrue,
          reason: 'a run was wiped before it finished scheduling',
        );
      }

      // Last-wins: the final slate is built from `third`, the stale middle
      // burst entry never runs.
      final List<String> finalSlate = schedulesAfterLastCancel();
      expect(finalSlate, contains('schedule:Dnes: Fresh C'));
      expect(finalSlate, contains('schedule:Za 10 min vyraz — Fresh C'));
      expect(finalSlate.join(), isNot(contains('Stale B')));
    },
  );

  test('a failed run does not break later reschedules', () async {
    final DateTime tomorrow20 = DateTime.now()
        .add(const Duration(days: 1))
        .copyWith(hour: 20, minute: 0, second: 0, millisecond: 0);

    plugin.throwOnNextCancelAll = true;
    await service.reschedule(<CachedEventRow>[
      _event(id: 'e1', title: 'Doomed', startsAt: tomorrow20),
    ]);

    await service.reschedule(<CachedEventRow>[
      _event(id: 'e2', title: 'Healthy', startsAt: tomorrow20),
    ]);

    expect(schedulesAfterLastCancel(), contains('schedule:Dnes: Healthy'));
  });
}
