import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/agenda_screen.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';
import 'package:kp_mobile/features/system/server_status.dart';

import 'helpers/in_memory_db.dart';

class _StubSyncController extends SyncController {
  @override
  SyncState build() => const SyncState();

  @override
  Future<void> pullChanges({int batchSize = 500}) async {
    state = SyncState(lastSyncedAt: DateTime.now());
  }
}

class _StubServerStatusController extends ServerStatusController {
  @override
  ServerHealth build() => ServerHealth.ok;
}

CachedEventRow _row({
  required String id,
  required String title,
  required DateTime startsAt,
}) {
  return CachedEventRow(
    id: id,
    workspaceId: 'ws-1',
    title: title,
    category: 'concert',
    startsAt: startsAt,
    venueTimezone: 'Europe/Prague',
    status: 'planned',
    source: 'manual',
    version: 1,
    updatedAt: startsAt,
    cachedAt: startsAt,
  );
}

Widget _wrap(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: AgendaScreen()),
  );
}

List<Override> _overrides({
  required Stream<List<CachedEventRow>> agendaStream,
}) {
  return <Override>[
    agendaProvider.overrideWith((ref) => agendaStream),
    syncControllerProvider.overrideWith(_StubSyncController.new),
    serverStatusProvider.overrideWith(_StubServerStatusController.new),
  ];
}

void main() {
  setUpAll(() async => initializeDateFormatting('cs'));

  testWidgets('renders cached events ordered by start time', (tester) async {
    // Far-future dates so neither event lands in the 24-h "imminent" banner.
    final DateTime base = DateTime.utc(2099);
    final List<CachedEventRow> rows = <CachedEventRow>[
      _row(
        id: 'evt-1',
        title: 'PJ Harvey',
        startsAt: base.add(const Duration(days: 7)),
      ),
      _row(
        id: 'evt-2',
        title: 'Sokolov',
        startsAt: base.add(const Duration(days: 14)),
      ),
    ];
    final ProviderContainer container = ProviderContainer(
      overrides: _overrides(
        agendaStream: Stream<List<CachedEventRow>>.value(rows),
      ),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pump();

    expect(find.text('PJ Harvey'), findsOneWidget);
    expect(find.text('Sokolov'), findsOneWidget);
    final Iterable<ListTile> tiles = tester.widgetList<ListTile>(
      find.byType(ListTile),
    );
    expect((tiles.first.title! as Text).data, equals('PJ Harvey'));
  });

  testWidgets('shows empty-state message when cache is empty', (tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: _overrides(
        agendaStream: Stream<List<CachedEventRow>>.value(
          const <CachedEventRow>[],
        ),
      ),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await tester.pump();

    expect(find.textContaining('Žádné události'), findsOneWidget);
  });

  test('database upsert + read round-trips', () async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);

    final DateTime now = DateTime.now().toUtc();
    await db.upsertEvent(
      CachedEventsCompanion.insert(
        id: 'evt-1',
        workspaceId: 'ws-1',
        title: 'Test',
        category: 'concert',
        startsAt: now,
        endsAt: const Value<DateTime?>(null),
        venueTimezone: const Value<String?>(null),
        status: 'planned',
        source: 'manual',
        notes: const Value<String?>(null),
        version: 1,
        updatedAt: now,
        deletedAt: const Value<DateTime?>(null),
        cachedAt: now,
      ),
    );

    final CachedEventRow? row = await db.findEvent('evt-1');
    expect(row, isNotNull);
    expect(row!.title, equals('Test'));
  });
}
