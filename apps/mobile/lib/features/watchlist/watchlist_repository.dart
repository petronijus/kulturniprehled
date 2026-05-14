import 'package:dio/dio.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/watchlist/watchlist_dto.dart';

// Offline-first watchlist repository.
//
// Reads come from the local drift cache (populated by the sync controller
// after pulling /v1/sync change_log entries). Writes hit the REST endpoints
// directly — V1 requires network for mutations. The newly-written row is
// applied to the cache immediately (optimistic) and the next sync pull
// reconciles any drift.

class WatchlistRepository {
  WatchlistRepository(this._db, this._client);

  final KpDatabase _db;
  final KpClient _client;

  Stream<List<CachedWatchlistItemRow>> watchAll() => _db.watchWatchlist();

  Future<CachedWatchlistItemRow?> findItem(String id) =>
      _db.findWatchlistItem(id);

  Future<WatchlistItemDto> createItem({
    required String title,
    required String kind,
    String? parentId,
    String? note,
    String? afterId,
    String? beforeId,
  }) async {
    final Response<dynamic> response = await _client.dio.post<dynamic>(
      '/v1/watchlist',
      data: <String, Object?>{
        'title': title,
        'kind': kind,
        'parent_id': ?parentId,
        'note': ?note,
        'after_id': ?afterId,
        'before_id': ?beforeId,
      },
    );
    final WatchlistItemDto dto = WatchlistItemDto.fromMap(
      response.data! as Map<String, dynamic>,
    );
    await _db.upsertWatchlistItem(dto.toCompanion());
    return dto;
  }

  Future<WatchlistItemDto> updateItem({
    required String id,
    required int version,
    String? title,
    String? kind,
    String? note,
  }) async {
    final Response<dynamic> response = await _client.dio.patch<dynamic>(
      '/v1/watchlist/$id',
      data: <String, Object?>{
        'version': version,
        'title': ?title,
        'kind': ?kind,
        'note': ?note,
      },
    );
    final WatchlistItemDto dto = WatchlistItemDto.fromMap(
      response.data! as Map<String, dynamic>,
    );
    await _db.upsertWatchlistItem(dto.toCompanion());
    return dto;
  }

  Future<WatchlistItemDto> setDone({
    required String id,
    required int version,
    required bool done,
  }) async {
    final Response<dynamic> response = await _client.dio.post<dynamic>(
      '/v1/watchlist/$id/check',
      data: <String, Object?>{'version': version, 'done': done},
    );
    final WatchlistItemDto dto = WatchlistItemDto.fromMap(
      response.data! as Map<String, dynamic>,
    );
    await _db.upsertWatchlistItem(dto.toCompanion());
    return dto;
  }

  Future<WatchlistItemDto> moveItem({
    required String id,
    required int version,
    String? parentId,
    bool setParent = false,
    String? afterId,
    String? beforeId,
    bool toEnd = false,
  }) async {
    final Response<dynamic> response = await _client.dio.post<dynamic>(
      '/v1/watchlist/$id/move',
      data: <String, Object?>{
        'version': version,
        if (setParent) 'parent_id': parentId,
        'set_parent': setParent,
        'after_id': ?afterId,
        'before_id': ?beforeId,
        'to_end': toEnd,
      },
    );
    final WatchlistItemDto dto = WatchlistItemDto.fromMap(
      response.data! as Map<String, dynamic>,
    );
    await _db.upsertWatchlistItem(dto.toCompanion());
    return dto;
  }

  Future<void> deleteItem(String id) async {
    await _client.dio.delete<void>('/v1/watchlist/$id');
    // Optimistic local soft-delete; the next sync pull will deliver the
    // tombstone(s) for parent + children to settle the cache properly.
    final CachedWatchlistItemRow? row = await _db.findWatchlistItem(id);
    if (row != null) {
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
          updatedAt: DateTime.now().toUtc(),
          deletedAt: drift.Value<DateTime?>(DateTime.now().toUtc()),
          cachedAt: DateTime.now().toUtc(),
        ),
      );
    }
  }
}

final Provider<WatchlistRepository> watchlistRepositoryProvider =
    Provider<WatchlistRepository>(
      (ref) => WatchlistRepository(
        ref.read(kpDatabaseProvider),
        ref.read(kpClientProvider),
      ),
    );

final StreamProvider<List<CachedWatchlistItemRow>> watchlistProvider =
    StreamProvider<List<CachedWatchlistItemRow>>(
      (ref) => ref.read(watchlistRepositoryProvider).watchAll(),
    );
