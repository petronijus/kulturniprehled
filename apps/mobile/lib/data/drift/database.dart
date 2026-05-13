import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

// Local cache of the KP entities the mobile app reads while offline. The
// server is the source of truth — every row here originated from a
// `/v1/sync` change_log entry. `cachedAt` is the local clock at the time of
// upsert and exists only for stale-while-revalidate UX, never for sync
// decisions.

@DataClassName('CachedEventRow')
class CachedEvents extends Table {
  TextColumn get id => text()();
  TextColumn get workspaceId => text()();
  TextColumn get title => text()();
  TextColumn get category => text()();
  DateTimeColumn get startsAt => dateTime()();
  DateTimeColumn get endsAt => dateTime().nullable()();
  TextColumn get venueTimezone => text().nullable()();
  TextColumn get status => text()();
  TextColumn get source => text()();
  TextColumn get notes => text().nullable()();
  IntColumn get version => integer()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('CachedTicketRow')
class CachedTickets extends Table {
  TextColumn get id => text()();
  TextColumn get eventId => text()();
  TextColumn get workspaceId => text()();
  TextColumn get mimeType => text()();
  TextColumn get originalFilename => text().nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  TextColumn get hashSha256 => text().nullable()();
  IntColumn get version => integer()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('SyncCursorRow')
class SyncCursors extends Table {
  // Always exactly one row (id=0). Drift refuses table-level singletons
  // declaratively, so we just upsert by id.
  IntColumn get id => integer().withDefault(const Constant(0))();
  IntColumn get seq => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DriftDatabase(tables: <Type>[CachedEvents, CachedTickets, SyncCursors])
class KpDatabase extends _$KpDatabase {
  KpDatabase() : super(_openConnection());
  KpDatabase.test(super.executor);

  @override
  int get schemaVersion => 1;

  Future<List<CachedEventRow>> watchUpcomingEvents() {
    final DateTime now = DateTime.now();
    return (select(cachedEvents)
          ..where(
            (tbl) =>
                tbl.deletedAt.isNull() & tbl.startsAt.isBiggerOrEqualValue(now),
          )
          ..orderBy(<OrderClauseGenerator<CachedEvents>>[
            (tbl) => OrderingTerm(expression: tbl.startsAt),
          ]))
        .get();
  }

  Stream<List<CachedEventRow>> watchAgenda() {
    return (select(cachedEvents)
          ..where((tbl) => tbl.deletedAt.isNull())
          ..orderBy(<OrderClauseGenerator<CachedEvents>>[
            (tbl) => OrderingTerm(expression: tbl.startsAt),
          ]))
        .watch();
  }

  Future<CachedEventRow?> findEvent(String id) async {
    return (select(
      cachedEvents,
    )..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
  }

  Future<List<CachedTicketRow>> ticketsForEvent(String eventId) {
    return (select(cachedTickets)
          ..where((tbl) => tbl.deletedAt.isNull() & tbl.eventId.equals(eventId))
          ..orderBy(<OrderClauseGenerator<CachedTickets>>[
            (tbl) => OrderingTerm(expression: tbl.cachedAt),
          ]))
        .get();
  }

  Future<void> upsertEvent(CachedEventsCompanion row) =>
      into(cachedEvents).insertOnConflictUpdate(row);

  Future<void> upsertTicket(CachedTicketsCompanion row) =>
      into(cachedTickets).insertOnConflictUpdate(row);

  Future<int?> readCursor() async {
    final SyncCursorRow? row = await (select(
      syncCursors,
    )..where((tbl) => tbl.id.equals(0))).getSingleOrNull();
    return row?.seq;
  }

  Future<void> writeCursor(int seq) async {
    await into(syncCursors).insertOnConflictUpdate(
      SyncCursorsCompanion(
        id: const Value<int>(0),
        seq: Value<int>(seq),
        lastSyncedAt: Value<DateTime>(DateTime.now()),
      ),
    );
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final File file = File(p.join(dir.path, 'kp_mobile.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

final Provider<KpDatabase> kpDatabaseProvider = Provider<KpDatabase>((ref) {
  final KpDatabase db = KpDatabase();
  ref.onDispose(() async => db.close());
  return db;
});
