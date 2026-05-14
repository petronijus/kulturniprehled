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

@DataClassName('PendingOpRow')
class PendingOps extends Table {
  // Client-generated UUID — the server uses it as the idempotency key for
  // POST /v1/sync/apply. Retrying the same op_id is byte-equal idempotent.
  TextColumn get opId => text()();
  TextColumn get entityType => text()();
  TextColumn get op => text()(); // "create" | "update" | "delete"
  TextColumn get entityId => text().nullable()();
  IntColumn get baseVersion => integer().nullable()();
  TextColumn get payloadJson => text()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  // After server applies, mark briefly so the UI can show a checkmark before
  // we delete the row. NULL while still pending.
  DateTimeColumn get appliedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{opId};
}

@DataClassName('CachedTicketFileRow')
class CachedTicketFiles extends Table {
  TextColumn get ticketId => text()();
  TextColumn get localPath => text()();
  TextColumn get mimeType => text()();
  IntColumn get sizeBytes => integer().nullable()();
  TextColumn get hashSha256 => text().nullable()();
  DateTimeColumn get downloadedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{ticketId};
}

@DataClassName('CachedWatchlistItemRow')
class CachedWatchlistItems extends Table {
  // Mirror of the server-side `watchlist_items` row. Position is the server
  // float — UI orders rows on it directly. parent_id NULL = root item.
  TextColumn get id => text()();
  TextColumn get workspaceId => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get title => text()();
  TextColumn get kind => text()(); // "film" | "divadlo" | "koncert"
  TextColumn get note => text().nullable()();
  RealColumn get position => real()();
  BoolColumn get done => boolean()();
  DateTimeColumn get doneAt => dateTime().nullable()();
  TextColumn get doneBy => text().nullable()();
  TextColumn get createdBy => text()();
  IntColumn get version => integer()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('CachedCostRow')
class CachedCosts extends Table {
  // All amounts are CZK haléře. Multi-currency was dropped before v1.0.
  TextColumn get id => text()();
  TextColumn get eventId => text()();
  TextColumn get workspaceId => text()();
  IntColumn get amountCents => integer()();
  TextColumn get kind => text()();
  TextColumn get paidBy => text()();
  TextColumn get split => text()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get paidAt => dateTime()();
  IntColumn get version => integer()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DriftDatabase(
  tables: <Type>[
    CachedEvents,
    CachedTickets,
    SyncCursors,
    PendingOps,
    CachedTicketFiles,
    CachedCosts,
    CachedWatchlistItems,
  ],
)
class KpDatabase extends _$KpDatabase {
  KpDatabase() : super(_openConnection());
  KpDatabase.test(super.executor);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) => m.createAll(),
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) {
        await m.createTable(pendingOps);
        await m.createTable(cachedTicketFiles);
      }
      if (from < 3) {
        await m.createTable(cachedCosts);
      }
      if (from < 4) {
        // Backend dropped multi-currency in 0006; align the local cache.
        // ALTER TABLE DROP COLUMN works on SQLite 3.35+ (Drift bundles
        // a newer build via sqlite3_flutter_libs).
        await m.database.customStatement(
          'ALTER TABLE cached_costs DROP COLUMN currency',
        );
      }
      if (from < 5) {
        await m.createTable(cachedWatchlistItems);
      }
    },
  );

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

  Future<CachedTicketRow?> findTicket(String id) async {
    return (select(
      cachedTickets,
    )..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
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

  // ===== Outbox / pending ops =====

  Future<void> insertPendingOp(PendingOpsCompanion row) =>
      into(pendingOps).insert(row);

  Future<List<PendingOpRow>> readPendingBatch({int limit = 50}) {
    return (select(pendingOps)
          ..where((tbl) => tbl.appliedAt.isNull())
          ..orderBy(<OrderClauseGenerator<PendingOps>>[
            (tbl) => OrderingTerm(expression: tbl.createdAt),
          ])
          ..limit(limit))
        .get();
  }

  Future<int> countPending() async {
    final Expression<int> total = pendingOps.opId.count();
    final TypedResult row =
        await (selectOnly(pendingOps)
              ..where(pendingOps.appliedAt.isNull())
              ..addColumns(<Expression<Object>>[total]))
            .getSingle();
    return row.read(total) ?? 0;
  }

  Stream<int> watchPendingCount() {
    final Expression<int> total = pendingOps.opId.count();
    return (selectOnly(pendingOps)
          ..where(pendingOps.appliedAt.isNull())
          ..addColumns(<Expression<Object>>[total]))
        .watchSingle()
        .map((row) => row.read(total) ?? 0);
  }

  Future<void> markPendingApplied(String opId) async {
    await (update(pendingOps)..where((tbl) => tbl.opId.equals(opId))).write(
      PendingOpsCompanion(appliedAt: Value<DateTime>(DateTime.now())),
    );
  }

  Future<void> markPendingError(String opId, String error) async {
    final PendingOpRow? row = await (select(
      pendingOps,
    )..where((tbl) => tbl.opId.equals(opId))).getSingleOrNull();
    if (row == null) {
      return;
    }
    await (update(pendingOps)..where((tbl) => tbl.opId.equals(opId))).write(
      PendingOpsCompanion(
        attempts: Value<int>(row.attempts + 1),
        lastError: Value<String?>(error),
        lastAttemptAt: Value<DateTime>(DateTime.now()),
      ),
    );
  }

  Future<void> deletePending(String opId) async {
    await (delete(pendingOps)..where((tbl) => tbl.opId.equals(opId))).go();
  }

  // ===== Ticket file cache =====

  Future<CachedTicketFileRow?> findTicketFile(String ticketId) {
    return (select(
      cachedTicketFiles,
    )..where((tbl) => tbl.ticketId.equals(ticketId))).getSingleOrNull();
  }

  Future<void> upsertTicketFile(CachedTicketFilesCompanion row) =>
      into(cachedTicketFiles).insertOnConflictUpdate(row);

  // ===== Costs =====

  Future<List<CachedCostRow>> costsForEvent(String eventId) {
    return (select(cachedCosts)
          ..where((tbl) => tbl.deletedAt.isNull() & tbl.eventId.equals(eventId))
          ..orderBy(<OrderClauseGenerator<CachedCosts>>[
            (tbl) => OrderingTerm(expression: tbl.paidAt),
          ]))
        .get();
  }

  Future<CachedCostRow?> findCost(String id) async {
    return (select(
      cachedCosts,
    )..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
  }

  Future<void> upsertCost(CachedCostsCompanion row) =>
      into(cachedCosts).insertOnConflictUpdate(row);

  // ===== Watchlist =====

  Stream<List<CachedWatchlistItemRow>> watchWatchlist() {
    // Roots first (parentId IS NULL → NULL sorts first in SQLite asc), then
    // children of each parent. Order within scope is by `position`.
    return (select(cachedWatchlistItems)
          ..where((tbl) => tbl.deletedAt.isNull())
          ..orderBy(<OrderClauseGenerator<CachedWatchlistItems>>[
            (tbl) => OrderingTerm(expression: tbl.parentId),
            (tbl) => OrderingTerm(expression: tbl.position),
          ]))
        .watch();
  }

  Future<CachedWatchlistItemRow?> findWatchlistItem(String id) {
    return (select(
      cachedWatchlistItems,
    )..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
  }

  Future<void> upsertWatchlistItem(CachedWatchlistItemsCompanion row) =>
      into(cachedWatchlistItems).insertOnConflictUpdate(row);
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
