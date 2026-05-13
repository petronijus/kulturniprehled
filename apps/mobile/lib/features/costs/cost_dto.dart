import 'package:drift/drift.dart' show Value;

import 'package:kp_mobile/data/drift/database.dart' as drift;

// Plain-data shape of a cost. Mirrors `serialize_cost` in
// apps/api/src/kp_api/sync/changelog.py. Amounts are CZK haléře —
// multi-currency was dropped before v1.0.

class CostDto {
  const CostDto({
    required this.id,
    required this.eventId,
    required this.workspaceId,
    required this.amountCents,
    required this.kind,
    required this.paidBy,
    required this.split,
    required this.note,
    required this.paidAt,
    required this.version,
    required this.updatedAt,
    required this.deletedAt,
  });

  factory CostDto.fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(String key) {
      final Object? value = map[key];
      if (value == null) {
        return null;
      }
      return DateTime.parse(value as String);
    }

    return CostDto(
      id: map['id'] as String,
      eventId: map['event_id'] as String,
      workspaceId: map['workspace_id'] as String,
      amountCents: map['amount_cents'] as int,
      kind: map['kind'] as String,
      paidBy: map['paid_by'] as String,
      split: map['split'] as String,
      note: map['note'] as String?,
      paidAt: DateTime.parse(map['paid_at'] as String),
      version: map['version'] as int,
      updatedAt: DateTime.parse(map['updated_at'] as String),
      deletedAt: parseDate('deleted_at'),
    );
  }

  final String id;
  final String eventId;
  final String workspaceId;
  final int amountCents;
  final String kind;
  final String paidBy;
  final String split;
  final String? note;
  final DateTime paidAt;
  final int version;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  drift.CachedCostsCompanion toCompanion() {
    return drift.CachedCostsCompanion.insert(
      id: id,
      eventId: eventId,
      workspaceId: workspaceId,
      amountCents: amountCents,
      kind: kind,
      paidBy: paidBy,
      split: split,
      note: Value<String?>(note),
      paidAt: paidAt,
      version: version,
      updatedAt: updatedAt,
      deletedAt: Value<DateTime?>(deletedAt),
      cachedAt: DateTime.now().toUtc(),
    );
  }
}
