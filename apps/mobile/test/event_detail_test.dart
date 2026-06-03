import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

Widget _appWithStub(CachedEventRow event) {
  final KpDatabase db = buildInMemoryDatabase();
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
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  setUpAll(() async => initializeDateFormatting('cs'));

  testWidgets('shows playlist link when the event has one', (tester) async {
    final CachedEventRow event = _makeEvent(
      spotifyPlaylistUrl: 'https://open.spotify.com/playlist/abc',
    );

    await tester.pumpWidget(_appWithStub(event));
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
    final CachedEventRow event = _makeEvent();

    await tester.pumpWidget(_appWithStub(event));
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(find.text('Playlist na Spotify', skipOffstage: false), findsNothing);
  });
}
