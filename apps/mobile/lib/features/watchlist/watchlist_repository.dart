import 'package:drift/drift.dart' as drift;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/outbox/outbox_controller.dart';

// Offline-first watchlist repository.
//
// Reads come from the local drift cache (populated by the sync controller
// after pulling /v1/sync change_log entries). Writes follow the same outbox
// pattern as events: every mutation is appended to `pending_ops` and the
// optimistic local row is upserted into drift immediately, so the UI sees
// the change before the network round-trip. The next /v1/sync pull replaces
// the optimistic row with the server's authoritative payload.
//
// `WatchlistOfflineUnsupported` is thrown only on the very first add before
// any /v1/sync pull has populated `workspace_id`; once the user is online
// once, subsequent mutations work fully offline.

class WatchlistOfflineUnsupported implements Exception {
  const WatchlistOfflineUnsupported();

  @override
  String toString() =>
      'Watchlist mutations require an initial sync to learn the workspace id.';
}

class WatchlistRepository {
  WatchlistRepository(this._db, this._ref);

  final KpDatabase _db;
  final Ref _ref;

  static const Uuid _uuid = Uuid();

  Stream<List<CachedWatchlistItemRow>> watchAll() => _db.watchWatchlist();

  Future<CachedWatchlistItemRow?> findItem(String id) =>
      _db.findWatchlistItem(id);

  Future<void> createItem({
    required String title,
    required String kind,
    String? parentId,
    String? note,
    String? afterId,
    String? beforeId,
  }) async {
    final String? workspaceId = await _db.anyCachedWorkspaceId();
    if (workspaceId == null) {
      throw const WatchlistOfflineUnsupported();
    }
    final String id = _uuid.v4();
    final DateTime now = DateTime.now().toUtc();
    final double position = await _optimisticPosition(
      parentId: parentId,
      afterId: afterId,
      beforeId: beforeId,
    );
    await _db.upsertWatchlistItem(
      CachedWatchlistItemsCompanion.insert(
        id: id,
        workspaceId: workspaceId,
        parentId: drift.Value<String?>(parentId),
        title: title,
        kind: kind,
        note: drift.Value<String?>(note),
        position: position,
        done: false,
        doneAt: const drift.Value<DateTime?>(null),
        doneBy: const drift.Value<String?>(null),
        // The server will overwrite this with the authoritative actor on
        // the next /v1/sync pull. Empty string is a sentinel "pending".
        createdBy: '',
        version: 1,
        updatedAt: now,
        deletedAt: const drift.Value<DateTime?>(null),
        cachedAt: now,
      ),
    );
    final Map<String, Object?> payload = <String, Object?>{
      'title': title,
      'kind': kind,
      'parent_id': ?parentId,
      'note': ?note,
      'after_id': ?afterId,
      'before_id': ?beforeId,
    };
    await _ref
        .read(outboxControllerProvider.notifier)
        .queueWatchlistCreate(entityId: id, payload: payload);
  }

  Future<void> updateItem({
    required String id,
    required int version,
    String? title,
    String? kind,
    String? note,
  }) async {
    final CachedWatchlistItemRow? row = await _db.findWatchlistItem(id);
    if (row == null) {
      return;
    }
    final DateTime now = DateTime.now().toUtc();
    await _db.upsertWatchlistItem(
      CachedWatchlistItemsCompanion.insert(
        id: row.id,
        workspaceId: row.workspaceId,
        parentId: drift.Value<String?>(row.parentId),
        title: title ?? row.title,
        kind: kind ?? row.kind,
        note: drift.Value<String?>(note ?? row.note),
        position: row.position,
        done: row.done,
        doneAt: drift.Value<DateTime?>(row.doneAt),
        doneBy: drift.Value<String?>(row.doneBy),
        createdBy: row.createdBy,
        version: row.version + 1,
        updatedAt: now,
        deletedAt: drift.Value<DateTime?>(row.deletedAt),
        cachedAt: now,
      ),
    );
    final Map<String, Object?> fields = <String, Object?>{
      'title': ?title,
      'kind': ?kind,
      'note': ?note,
    };
    await _ref
        .read(outboxControllerProvider.notifier)
        .queueWatchlistUpdate(
          entityId: id,
          baseVersion: version,
          fields: fields,
        );
  }

  Future<void> setDone({
    required String id,
    required int version,
    required bool done,
  }) async {
    final CachedWatchlistItemRow? row = await _db.findWatchlistItem(id);
    if (row == null) {
      return;
    }
    if (row.done == done) {
      // Mirror the REST endpoint's no-op short-circuit so spamming the
      // checkbox doesn't enqueue a useless server round-trip.
      return;
    }
    final DateTime now = DateTime.now().toUtc();
    await _db.upsertWatchlistItem(
      CachedWatchlistItemsCompanion.insert(
        id: row.id,
        workspaceId: row.workspaceId,
        parentId: drift.Value<String?>(row.parentId),
        title: row.title,
        kind: row.kind,
        note: drift.Value<String?>(row.note),
        position: row.position,
        done: done,
        doneAt: drift.Value<DateTime?>(done ? now : null),
        // `done_by` becomes authoritative on the next sync pull. Optimistic
        // local row mirrors the original creator so the field is non-null
        // when `done` is true.
        doneBy: drift.Value<String?>(done ? row.createdBy : null),
        createdBy: row.createdBy,
        version: row.version + 1,
        updatedAt: now,
        deletedAt: drift.Value<DateTime?>(row.deletedAt),
        cachedAt: now,
      ),
    );
    await _ref
        .read(outboxControllerProvider.notifier)
        .queueWatchlistUpdate(
          entityId: id,
          baseVersion: version,
          fields: <String, Object?>{'done': done},
        );
  }

  Future<void> moveItem({
    required String id,
    required int version,
    String? parentId,
    bool setParent = false,
    String? afterId,
    String? beforeId,
    bool toEnd = false,
  }) async {
    final CachedWatchlistItemRow? row = await _db.findWatchlistItem(id);
    if (row == null) {
      return;
    }
    final String? newParentId = setParent ? parentId : row.parentId;
    final double newPosition = await _optimisticPosition(
      parentId: newParentId,
      afterId: afterId,
      beforeId: beforeId,
      movingId: id,
    );
    final DateTime now = DateTime.now().toUtc();
    await _db.upsertWatchlistItem(
      CachedWatchlistItemsCompanion.insert(
        id: row.id,
        workspaceId: row.workspaceId,
        parentId: drift.Value<String?>(newParentId),
        title: row.title,
        kind: row.kind,
        note: drift.Value<String?>(row.note),
        position: newPosition,
        done: row.done,
        doneAt: drift.Value<DateTime?>(row.doneAt),
        doneBy: drift.Value<String?>(row.doneBy),
        createdBy: row.createdBy,
        version: row.version + 1,
        updatedAt: now,
        deletedAt: drift.Value<DateTime?>(row.deletedAt),
        cachedAt: now,
      ),
    );
    final Map<String, Object?> payload = <String, Object?>{
      if (setParent) 'parent_id': parentId,
      'set_parent': setParent,
      'after_id': ?afterId,
      'before_id': ?beforeId,
      'to_end': toEnd,
    };
    await _ref
        .read(outboxControllerProvider.notifier)
        .queueWatchlistMove(
          entityId: id,
          baseVersion: version,
          payload: payload,
        );
  }

  Future<void> deleteItem(String id) async {
    final CachedWatchlistItemRow? row = await _db.findWatchlistItem(id);
    if (row == null) {
      // Already gone locally — still queue so the server applies idempotently.
      await _ref
          .read(outboxControllerProvider.notifier)
          .queueWatchlistDelete(entityId: id);
      return;
    }
    final DateTime now = DateTime.now().toUtc();
    // Roots cascade to children — mirror the server's behaviour so the
    // optimistic UI matches what /v1/sync will eventually deliver.
    if (row.parentId == null) {
      final List<CachedWatchlistItemRow> all = await _db.watchWatchlist().first;
      for (final CachedWatchlistItemRow child in all) {
        if (child.parentId == row.id && child.deletedAt == null) {
          await _db.upsertWatchlistItem(
            CachedWatchlistItemsCompanion.insert(
              id: child.id,
              workspaceId: child.workspaceId,
              parentId: drift.Value<String?>(child.parentId),
              title: child.title,
              kind: child.kind,
              note: drift.Value<String?>(child.note),
              position: child.position,
              done: child.done,
              doneAt: drift.Value<DateTime?>(child.doneAt),
              doneBy: drift.Value<String?>(child.doneBy),
              createdBy: child.createdBy,
              version: child.version + 1,
              updatedAt: now,
              deletedAt: drift.Value<DateTime?>(now),
              cachedAt: now,
            ),
          );
        }
      }
    }
    await _db.upsertWatchlistItem(
      CachedWatchlistItemsCompanion.insert(
        id: row.id,
        workspaceId: row.workspaceId,
        parentId: drift.Value<String?>(row.parentId),
        title: row.title,
        kind: row.kind,
        note: drift.Value<String?>(row.note),
        position: row.position,
        done: row.done,
        doneAt: drift.Value<DateTime?>(row.doneAt),
        doneBy: drift.Value<String?>(row.doneBy),
        createdBy: row.createdBy,
        version: row.version + 1,
        updatedAt: now,
        deletedAt: drift.Value<DateTime?>(now),
        cachedAt: now,
      ),
    );
    await _ref
        .read(outboxControllerProvider.notifier)
        .queueWatchlistDelete(entityId: id);
  }

  /// Computes the fractional rank a new or moved item should claim, mirroring
  /// the server's logic in `kp_api.sync.service._compute_watchlist_position`.
  /// The eventual /v1/sync pull replaces this with the canonical value if
  /// they ever diverge, so a small mismatch (e.g. a concurrent add by the
  /// other workspace member) is self-healing.
  Future<double> _optimisticPosition({
    required String? parentId,
    required String? afterId,
    required String? beforeId,
    String? movingId,
  }) async {
    final List<CachedWatchlistItemRow> all = await _db.watchWatchlist().first;
    final List<CachedWatchlistItemRow> scope =
        all
            .where(
              (r) =>
                  r.parentId == parentId &&
                  r.deletedAt == null &&
                  r.id != movingId,
            )
            .toList()
          ..sort((a, b) => a.position.compareTo(b.position));

    if (afterId != null) {
      final int i = scope.indexWhere((r) => r.id == afterId);
      if (i < 0) {
        return scope.isEmpty ? 1.0 : scope.last.position + 1.0;
      }
      final double anchor = scope[i].position;
      if (i + 1 < scope.length) {
        return (anchor + scope[i + 1].position) / 2;
      }
      return anchor + 1.0;
    }
    if (beforeId != null) {
      final int i = scope.indexWhere((r) => r.id == beforeId);
      if (i < 0) {
        return scope.isEmpty ? 1.0 : scope.last.position + 1.0;
      }
      final double anchor = scope[i].position;
      if (i - 1 >= 0) {
        return (scope[i - 1].position + anchor) / 2;
      }
      return anchor - 1.0;
    }
    return scope.isEmpty ? 1.0 : scope.last.position + 1.0;
  }
}

final Provider<WatchlistRepository> watchlistRepositoryProvider =
    Provider<WatchlistRepository>(
      (ref) => WatchlistRepository(ref.read(kpDatabaseProvider), ref),
    );

final StreamProvider<List<CachedWatchlistItemRow>> watchlistProvider =
    StreamProvider<List<CachedWatchlistItemRow>>(
      (ref) => ref.read(watchlistRepositoryProvider).watchAll(),
    );
