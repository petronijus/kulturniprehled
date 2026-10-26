import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/data/storage/token_store.dart';
import 'package:kp_mobile/features/notifications/event_notification.dart';
import 'package:kp_mobile/features/notifications/notification_service.dart';
import 'package:kp_mobile/features/outbox/outbox_controller.dart';
import 'package:kp_mobile/features/sync/offline_cache_service.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';

import 'helpers/in_memory_db.dart';

// Event notifications are decided by the server and arrive through
// /v1/sync; the phone shows each one once, when it is due on the server
// clock. These tests pin the delivery rules and the rendered text.

final DateTime _t0 = DateTime.utc(2026, 10, 26, 9);

// The event starts 2026-10-31 17:00 UTC, a Saturday; the hour depends on
// the zone the tests run in, so it is formatted the same way here.
final String _when =
    'Sobota ${DateFormat("d.M. 'v' HH:mm", 'cs').format(DateTime.utc(2026, 10, 31, 17).toLocal())}';

Map<String, Object?> _eventPayload({
  String id = 'evt-1',
  String? venue = 'Národní divadlo, Praha',
  DateTime? deletedAt,
}) => <String, Object?>{
  'id': id,
  'workspace_id': 'ws-1',
  'title': 'Pelléas et Mélisande',
  'category': 'concert',
  'venue_id': null,
  'starts_at': DateTime.utc(2026, 10, 31, 17).toIso8601String(),
  'ends_at': null,
  'venue_timezone': 'Europe/Prague',
  'status': 'planned',
  'source': 'skill',
  'notes': 'Debussy',
  'cover_image_url': null,
  'venue_image_url': null,
  'venue_address': venue,
  'departure_at': null,
  'spotify_playlist_url': null,
  'created_by': 'user-petr',
  'version': 1,
  'created_at': _t0.toIso8601String(),
  'updated_at': _t0.toIso8601String(),
  'deleted_at': deletedAt?.toIso8601String(),
};

Map<String, Object?> _notificationPayload({
  String id = 'ntf-1',
  String eventId = 'evt-1',
  String kind = 'event_created',
  List<String> changes = const <String>[],
  String? message,
  DateTime? deliverAfter,
  int version = 1,
}) => <String, Object?>{
  'id': id,
  'workspace_id': 'ws-1',
  'event_id': eventId,
  'kind': kind,
  'changes': changes,
  'message': message,
  'created_by': 'user-petr',
  'deliver_after': (deliverAfter ?? _t0).toIso8601String(),
  'version': version,
  'created_at': _t0.toIso8601String(),
  'updated_at': _t0.toIso8601String(),
  'deleted_at': null,
};

Map<String, Object?> _change(int seq, String type, Map<String, Object?> p) =>
    <String, Object?>{
      'seq': seq,
      'workspace_id': 'ws-1',
      'entity_type': type,
      'entity_id': p['id'],
      'op': 'upsert',
      'payload': p,
      'actor_id': 'user-petr',
      'created_at': _t0.toIso8601String(),
    };

class _NullTokenStore extends TokenStore {
  _NullTokenStore() : super();
  @override
  Future<TokenPair?> read() async => null;
  @override
  Future<void> write(TokenPair pair) async {}
  @override
  Future<void> clear() async {}
}

/// Serves queued /v1/sync pages; each pull consumes one.
class _SyncServer extends Interceptor {
  final List<Map<String, Object?>> pages = <Map<String, Object?>>[];

  void queue(List<Map<String, Object?>> changes, {required DateTime now}) {
    pages.add(<String, Object?>{
      'changes': changes,
      'next_seq': changes.isEmpty ? 0 : changes.last['seq'],
      'has_more': false,
      'server_time': now.toIso8601String(),
    });
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.resolve(
      Response<dynamic>(
        requestOptions: options,
        statusCode: 200,
        data: jsonDecode(jsonEncode(pages.removeAt(0))),
      ),
    );
  }
}

class _RecordingNotifications extends NotificationService {
  _RecordingNotifications() : super(FlutterLocalNotificationsPlugin());

  final List<String> shown = <String>[];
  int failuresLeft = 0;

  @override
  Future<void> showEventNotification(
    CachedNotificationRow notification,
    CachedEventRow event,
  ) async {
    if (failuresLeft > 0) {
      failuresLeft--;
      throw StateError('simulated platform failure');
    }
    shown.add(renderEventNotification(notification, event).title);
  }
}

class _NoOfflineCache extends OfflineCacheService {
  _NoOfflineCache(super.ref);
  @override
  Future<void> refresh() async {}
}

class _Harness {
  _Harness() {
    final Dio dio = Dio()..interceptors.add(server);
    container = ProviderContainer(
      overrides: <Override>[
        kpDatabaseProvider.overrideWithValue(db),
        kpClientProvider.overrideWith(
          (ref) => KpClient(_NullTokenStore(), dio: dio),
        ),
        notificationServiceProvider.overrideWithValue(notifications),
        offlineCacheServiceProvider.overrideWith(_NoOfflineCache.new),
      ],
    );
  }

  final KpDatabase db = buildInMemoryDatabase();
  final _SyncServer server = _SyncServer();
  final _RecordingNotifications notifications = _RecordingNotifications();
  late final ProviderContainer container;

  Future<void> pull() async {
    await container.read(syncControllerProvider.notifier).pullChanges();
    expect(container.read(syncControllerProvider).error, isNull);
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

CachedEventRow _eventRow({String? venue = 'Národní divadlo, Praha'}) =>
    CachedEventRow(
      id: 'evt-1',
      workspaceId: 'ws-1',
      title: 'Pelléas et Mélisande',
      category: 'concert',
      startsAt: DateTime.utc(2026, 10, 31, 17),
      status: 'planned',
      source: 'skill',
      venueAddress: venue,
      version: 1,
      updatedAt: _t0,
      cachedAt: _t0,
    );

CachedNotificationRow _notificationRow({
  String kind = 'event_created',
  List<String> changes = const <String>[],
  String? message,
}) => CachedNotificationRow(
  id: 'ntf-1',
  workspaceId: 'ws-1',
  eventId: 'evt-1',
  kind: kind,
  changesJson: jsonEncode(changes),
  message: message,
  createdBy: 'user-petr',
  deliverAfter: _t0,
  version: 1,
  updatedAt: _t0,
  cachedAt: _t0,
  attempts: 0,
);

void main() {
  setUpAll(() async => initializeDateFormatting('cs'));

  group('renderEventNotification', () {
    test('a new event names the date and the venue', () {
      final NotificationText text = renderEventNotification(
        _notificationRow(),
        _eventRow(),
      );
      expect(text.title, 'Nová akce: Pelléas et Mélisande');
      expect(text.body, '$_when — Národní divadlo, Praha');
    });

    test('a venue change says where, a programme change says so', () {
      final NotificationText text = renderEventNotification(
        _notificationRow(
          kind: 'event_changed',
          changes: <String>['program', 'venue'],
        ),
        _eventRow(),
      );
      expect(text.title, 'Změna: Pelléas et Mélisande');
      expect(
        text.body,
        'Nové místo: Národní divadlo, Praha\n'
        'Upravený program\n$_when',
      );
    });

    test('a removed venue is reported as removed', () {
      final NotificationText text = renderEventNotification(
        _notificationRow(kind: 'event_changed', changes: <String>['venue']),
        _eventRow(venue: null),
      );
      expect(text.body, 'Místo odstraněno\n$_when');
    });

    test('a manual notification leads with its message', () {
      final NotificationText text = renderEventNotification(
        _notificationRow(kind: 'manual', message: '  Nová fotka z premiéry '),
        _eventRow(),
      );
      expect(text.title, 'Pelléas et Mélisande');
      expect(
        text.body,
        'Nová fotka z premiéry\n'
        '$_when — Národní divadlo, Praha',
      );
    });

    test('a manual notification merged into a change keeps both', () {
      final NotificationText text = renderEventNotification(
        _notificationRow(
          kind: 'manual',
          changes: <String>['program'],
          message: 'Mrkni na obsazení',
        ),
        _eventRow(),
      );
      expect(text.title, 'Změna: Pelléas et Mélisande');
      expect(text.body, startsWith('Mrkni na obsazení\nUpravený program\n'));
    });
  });

  group('cache', () {
    test(
      'a re-sync of the shown version keeps it shown, a newer one is due',
      () async {
        final KpDatabase db = buildInMemoryDatabase();
        addTearDown(db.close);
        final DateTime later = _t0.add(const Duration(hours: 1));
        await db.upsertNotification(
          EventNotificationDto.fromMap(_notificationPayload()).toCompanion(),
        );
        await db.markNotificationShown('ntf-1', 1);

        await db.upsertNotification(
          EventNotificationDto.fromMap(_notificationPayload()).toCompanion(),
        );
        expect(await db.dueNotifications(later), isEmpty);

        // A merge that raced a pull near the deadline: shown again.
        await db.upsertNotification(
          EventNotificationDto.fromMap(
            _notificationPayload(version: 2, message: 'later'),
          ).toCompanion(),
        );
        expect((await db.dueNotifications(later)).single.message, 'later');
      },
    );

    test('due means past deliver_after, unshown and not deleted', () async {
      final KpDatabase db = buildInMemoryDatabase();
      addTearDown(db.close);
      await db.upsertNotification(
        EventNotificationDto.fromMap(_notificationPayload()).toCompanion(),
      );
      await db.upsertNotification(
        EventNotificationDto.fromMap(
          _notificationPayload(
            id: 'ntf-later',
            deliverAfter: _t0.add(const Duration(minutes: 2)),
          ),
        ).toCompanion(),
      );
      await db.upsertNotification(
        EventNotificationDto.fromMap(
          _notificationPayload(id: 'ntf-gone'),
        ).toCompanion().copyWith(deletedAt: Value<DateTime?>(_t0)),
      );

      final List<CachedNotificationRow> due = await db.dueNotifications(
        _t0.add(const Duration(minutes: 1)),
      );
      expect(due.map((n) => n.id), <String>['ntf-1']);
    });
  });

  group('delivery through sync', () {
    late _Harness h;

    setUp(() => h = _Harness());
    tearDown(() => h.dispose());

    test('the first sync of a fresh install shows nothing', () async {
      h.server.queue(<Map<String, Object?>>[
        _change(1, 'event', _eventPayload()),
        _change(2, 'notification', _notificationPayload()),
      ], now: _t0.add(const Duration(minutes: 5)));

      await h.pull();

      expect(h.notifications.shown, isEmpty);
      expect(
        await h.db.dueNotifications(_t0.add(const Duration(days: 1))),
        isEmpty,
      );
    });

    test('a due notification is shown once, a pending one when due', () async {
      h.server.queue(<Map<String, Object?>>[
        _change(1, 'event', _eventPayload(id: 'evt-0')),
      ], now: _t0);
      await h.pull();

      h.server
        ..queue(<Map<String, Object?>>[
          _change(2, 'event', _eventPayload()),
          _change(
            3,
            'notification',
            _notificationPayload(
              deliverAfter: _t0.add(const Duration(minutes: 2)),
            ),
          ),
        ], now: _t0.add(const Duration(minutes: 1)))
        ..queue(<Map<String, Object?>>[
          _change(
            4,
            'notification',
            _notificationPayload(
              changes: <String>['program'],
              deliverAfter: _t0.add(const Duration(minutes: 2)),
              version: 2,
            ),
          ),
        ], now: _t0.add(const Duration(minutes: 3)))
        ..queue(
          <Map<String, Object?>>[],
          now: _t0.add(const Duration(minutes: 30)),
        );

      await h.pull();
      expect(h.notifications.shown, isEmpty, reason: 'still collecting merges');

      await h.pull();
      expect(h.notifications.shown, <String>[
        'Nová akce: Pelléas et Mélisande',
      ]);

      await h.pull();
      expect(h.notifications.shown, hasLength(1));
    });

    test('the server clock decides, not the phone clock', () async {
      h.server.queue(<Map<String, Object?>>[
        _change(1, 'event', _eventPayload()),
      ], now: _t0);
      await h.pull();

      // deliver_after is far in the phone's past, but the server says it is
      // a minute early.
      final DateTime serverNow = DateTime.utc(2000);
      h.server.queue(<Map<String, Object?>>[
        _change(
          2,
          'notification',
          _notificationPayload(
            deliverAfter: serverNow.add(const Duration(minutes: 1)),
          ),
        ),
      ], now: serverNow);
      await h.pull();

      expect(h.notifications.shown, isEmpty);
    });

    test('a notification for a deleted event is dropped', () async {
      h.server.queue(<Map<String, Object?>>[
        _change(1, 'event', _eventPayload(id: 'evt-0')),
      ], now: _t0);
      await h.pull();

      h.server
        ..queue(<Map<String, Object?>>[
          _change(2, 'event', _eventPayload(deletedAt: _t0)),
          _change(3, 'notification', _notificationPayload()),
        ], now: _t0.add(const Duration(minutes: 5)))
        ..queue(<Map<String, Object?>>[
          _change(4, 'event', _eventPayload()),
        ], now: _t0.add(const Duration(minutes: 6)));

      await h.pull();
      await h.pull();

      expect(h.notifications.shown, isEmpty);
    });

    test('one overdue by more than a day is dropped', () async {
      h.server.queue(<Map<String, Object?>>[
        _change(1, 'event', _eventPayload()),
      ], now: _t0);
      await h.pull();

      h.server.queue(<Map<String, Object?>>[
        _change(2, 'notification', _notificationPayload()),
      ], now: _t0.add(const Duration(hours: 25)));
      await h.pull();

      expect(h.notifications.shown, isEmpty);
    });

    test('a failed show is retried on the next sync', () async {
      h.server.queue(<Map<String, Object?>>[
        _change(1, 'event', _eventPayload()),
      ], now: _t0);
      await h.pull();

      h.notifications.failuresLeft = 1;
      h.server
        ..queue(<Map<String, Object?>>[
          _change(
            2,
            'notification',
            _notificationPayload(kind: 'manual', message: 'Ahoj'),
          ),
        ], now: _t0.add(const Duration(minutes: 1)))
        ..queue(
          <Map<String, Object?>>[],
          now: _t0.add(const Duration(minutes: 30)),
        );

      await h.pull();
      expect(h.notifications.shown, isEmpty);

      await h.pull();
      expect(h.notifications.shown, <String>['Pelléas et Mélisande']);
    });
  });

  group('delivery edge cases', () {
    late _Harness h;

    setUp(() => h = _Harness());
    tearDown(() => h.dispose());

    test('a newer version of a shown notification is shown again', () async {
      h.server.queue(<Map<String, Object?>>[
        _change(1, 'event', _eventPayload()),
      ], now: _t0);
      await h.pull();

      h.server
        ..queue(<Map<String, Object?>>[
          _change(2, 'notification', _notificationPayload(kind: 'manual')),
        ], now: _t0.add(const Duration(seconds: 1)))
        ..queue(<Map<String, Object?>>[
          _change(
            3,
            'notification',
            _notificationPayload(
              kind: 'manual',
              message: 'Merged late',
              version: 2,
            ),
          ),
        ], now: _t0.add(const Duration(seconds: 2)));
      await h.pull();
      await h.pull();

      expect(h.notifications.shown, hasLength(2));
    });

    test('a fresh install still shows a notification not yet due', () async {
      h.server
        ..queue(<Map<String, Object?>>[
          _change(1, 'event', _eventPayload()),
          _change(
            2,
            'notification',
            _notificationPayload(
              deliverAfter: _t0.add(const Duration(minutes: 2)),
            ),
          ),
        ], now: _t0)
        ..queue(
          <Map<String, Object?>>[],
          now: _t0.add(const Duration(minutes: 3)),
        );

      await h.pull();
      expect(h.notifications.shown, isEmpty);
      await h.pull();
      expect(h.notifications.shown, <String>[
        'Nová akce: Pelléas et Mélisande',
      ]);
    });

    test(
      'a failing show records its error and is dropped once stale',
      () async {
        h.server.queue(<Map<String, Object?>>[
          _change(1, 'event', _eventPayload()),
        ], now: _t0);
        await h.pull();

        h.notifications.failuresLeft = 99;
        h.server
          ..queue(<Map<String, Object?>>[
            _change(2, 'notification', _notificationPayload()),
          ], now: _t0.add(const Duration(minutes: 1)))
          ..queue(
            <Map<String, Object?>>[],
            now: _t0.add(const Duration(minutes: 31)),
          )
          ..queue(
            <Map<String, Object?>>[],
            now: _t0.add(const Duration(hours: 25)),
          );

        await h.pull();
        await h.pull();
        final CachedNotificationRow failing = (await h.db.dueNotifications(
          _t0.add(const Duration(hours: 1)),
        )).single;
        expect(failing.attempts, 2);
        expect(failing.lastError, contains('simulated platform failure'));

        await h.pull();
        expect(
          await h.db.dueNotifications(_t0.add(const Duration(days: 2))),
          isEmpty,
        );
        expect(h.notifications.shown, isEmpty);
      },
    );
  });

  test('a manual notification is queued in the outbox', () async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        kpDatabaseProvider.overrideWithValue(db),
        kpClientProvider.overrideWith(
          (ref) => KpClient(
            _NullTokenStore(),
            dio: Dio()
              ..interceptors.add(
                InterceptorsWrapper(
                  onRequest: (options, handler) => handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.connectionError,
                    ),
                  ),
                ),
              ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(outboxControllerProvider.notifier)
        .queueEventNotification(eventId: 'evt-1', message: '  Ahoj  ');
    // The push it fires (offline here) must end before the container goes.
    while (container.read(outboxControllerProvider)) {
      await pumpEventQueue();
    }

    final List<PendingOpRow> pending = await db.readPendingBatch();
    expect(pending, hasLength(1));
    expect(pending.single.entityType, 'notification');
    expect(pending.single.op, 'create');
    expect(pending.single.entityId, 'evt-1');
    expect(jsonDecode(pending.single.payloadJson), <String, Object?>{
      'message': 'Ahoj',
    });
  });
}
