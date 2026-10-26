import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/event_detail_screen.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/outbox/outbox_controller.dart';

import 'helpers/in_memory_db.dart';

final DateTime _base = DateTime.utc(2099);

CachedEventRow _makeEvent({String? spotifyPlaylistUrl}) {
  return CachedEventRow(
    id: 'evt-1',
    workspaceId: 'ws-1',
    title: 'Sokolov',
    category: 'concert',
    startsAt: _base.add(const Duration(days: 7)),
    venueTimezone: 'Europe/Prague',
    status: 'planned',
    source: 'manual',
    spotifyPlaylistUrl: spotifyPlaylistUrl,
    version: 1,
    updatedAt: _base,
    cachedAt: _base,
  );
}

/// Stubs the events repository so [EventDetailScreen]'s FutureBuilder gets
/// a resolved [Future] immediately — no real DB round-trip needed.
class _SyncEventRepository extends EventsRepository {
  _SyncEventRepository(super.db, this._event);

  final CachedEventRow _event;

  @override
  Future<CachedEventRow?> getEvent(String id) =>
      Future<CachedEventRow?>.value(id == _event.id ? _event : null);

  @override
  Future<List<CachedTicketRow>> ticketsForEvent(String eventId) =>
      Future<List<CachedTicketRow>>.value(<CachedTicketRow>[]);
}

/// Records manual notification requests instead of touching the network.
class _RecordingOutbox extends OutboxController {
  final List<(String, String?)> notified = <(String, String?)>[];

  @override
  Future<String> queueEventNotification({
    required String eventId,
    String? message,
  }) async {
    notified.add((eventId, message));
    return 'op-1';
  }
}

Widget _appWithStub(
  CachedEventRow event,
  KpDatabase db, {
  _RecordingOutbox? outbox,
}) {
  final GoRouter router = GoRouter(
    initialLocation: '/event/evt-1',
    routes: <RouteBase>[
      GoRoute(
        path: '/event/:id',
        builder: (BuildContext context, GoRouterState state) =>
            const EventDetailScreen(eventId: 'evt-1'),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      kpDatabaseProvider.overrideWithValue(db),
      eventsRepositoryProvider.overrideWithValue(
        _SyncEventRepository(db, event),
      ),
      outboxConflictStreamProvider.overrideWith(
        (ref) => const Stream<OutboxConflict>.empty(),
      ),
      if (outbox != null) outboxControllerProvider.overrideWith(() => outbox),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  setUpAll(() async => initializeDateFormatting('cs'));

  testWidgets('shows playlist link when the event has one', (tester) async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    final CachedEventRow event = _makeEvent(
      spotifyPlaylistUrl: 'https://open.spotify.com/playlist/abc',
    );

    await tester.pumpWidget(_appWithStub(event, db));
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }

    // The playlist link is inside a ListView; skipOffstage: false ensures the
    // finder searches sliver children regardless of their paint status.
    expect(
      find.text('Playlist na Spotify', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('hides playlist link when the event has none', (tester) async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    final CachedEventRow event = _makeEvent();

    await tester.pumpWidget(_appWithStub(event, db));
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(find.text('Playlist na Spotify', skipOffstage: false), findsNothing);
  });

  testWidgets('the bell queues a notification with the typed message', (
    tester,
  ) async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    final _RecordingOutbox outbox = _RecordingOutbox();

    await tester.pumpWidget(_appWithStub(_makeEvent(), db, outbox: outbox));
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }

    await tester.tap(find.bySemanticsLabel('Poslat notifikaci'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Nová fotka');
    await tester.tap(find.text('Poslat'));
    await tester.pumpAndSettle();

    expect(outbox.notified, <(String, String?)>[('evt-1', 'Nová fotka')]);
    expect(
      find.text('Notifikace dorazí na oba telefony při příští synchronizaci.'),
      findsOneWidget,
    );
  });

  testWidgets('cancelling the dialog sends nothing', (tester) async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    final _RecordingOutbox outbox = _RecordingOutbox();

    await tester.pumpWidget(_appWithStub(_makeEvent(), db, outbox: outbox));
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }

    await tester.tap(find.bySemanticsLabel('Poslat notifikaci'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();

    expect(outbox.notified, isEmpty);
  });
}
