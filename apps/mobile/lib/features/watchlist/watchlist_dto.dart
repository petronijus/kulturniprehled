// Plain-data shape for a watchlist item. Mirrors `serialize_watchlist_item`
// in apps/api/src/kp_api/sync/changelog.py — keep them aligned by hand
// until we generate clients from the OpenAPI spec.

import 'package:drift/drift.dart' show Value;

import 'package:kp_mobile/data/drift/database.dart' as drift;

class WatchlistItemDto {
  const WatchlistItemDto({
    required this.id,
    required this.workspaceId,
    required this.parentId,
    required this.title,
    required this.kind,
    required this.note,
    required this.position,
    required this.done,
    required this.doneAt,
    required this.doneBy,
    required this.createdBy,
    required this.version,
    required this.updatedAt,
    required this.deletedAt,
  });

  factory WatchlistItemDto.fromMap(Map<String, dynamic> map) {
    DateTime? maybeDate(String key) {
      final Object? value = map[key];
      if (value == null) {
        return null;
      }
      return DateTime.parse(value as String);
    }

    return WatchlistItemDto(
      id: map['id'] as String,
      workspaceId: map['workspace_id'] as String,
      parentId: map['parent_id'] as String?,
      title: map['title'] as String,
      kind: map['kind'] as String,
      note: map['note'] as String?,
      // Server may serialise the float as int (e.g. 1) or as double; coerce.
      position: (map['position'] as num).toDouble(),
      done: map['done'] as bool,
      doneAt: maybeDate('done_at'),
      doneBy: map['done_by'] as String?,
      createdBy: map['created_by'] as String,
      version: map['version'] as int,
      updatedAt: DateTime.parse(map['updated_at'] as String),
      deletedAt: maybeDate('deleted_at'),
    );
  }

  final String id;
  final String workspaceId;
  final String? parentId;
  final String title;
  final String kind;
  final String? note;
  final double position;
  final bool done;
  final DateTime? doneAt;
  final String? doneBy;
  final String createdBy;
  final int version;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  drift.CachedWatchlistItemsCompanion toCompanion() {
    return drift.CachedWatchlistItemsCompanion.insert(
      id: id,
      workspaceId: workspaceId,
      parentId: Value<String?>(parentId),
      title: title,
      kind: kind,
      note: Value<String?>(note),
      position: position,
      done: done,
      doneAt: Value<DateTime?>(doneAt),
      doneBy: Value<String?>(doneBy),
      createdBy: createdBy,
      version: version,
      updatedAt: updatedAt,
      deletedAt: Value<DateTime?>(deletedAt),
      cachedAt: DateTime.now().toUtc(),
    );
  }
}
