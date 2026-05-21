// Plain-data shapes for events and tickets. We are not generating clients
// from OpenAPI yet (M5 scope) — the maps the server returns are decoded by
// hand. Keep these aligned with `serialize_event` in apps/api/src/kp_api/sync.

import 'package:drift/drift.dart' show Value;

import 'package:kp_mobile/data/drift/database.dart' as drift;

class EventDto {
  const EventDto({
    required this.id,
    required this.workspaceId,
    required this.title,
    required this.category,
    required this.startsAt,
    required this.endsAt,
    required this.venueTimezone,
    required this.status,
    required this.source,
    required this.notes,
    required this.coverImageUrl,
    required this.venueImageUrl,
    required this.venueAddress,
    required this.departureAt,
    required this.version,
    required this.updatedAt,
    required this.deletedAt,
  });

  factory EventDto.fromMap(Map<String, dynamic> map) {
    DateTime? maybeDate(String key) {
      final Object? value = map[key];
      if (value == null) {
        return null;
      }
      return DateTime.parse(value as String);
    }

    return EventDto(
      id: map['id'] as String,
      workspaceId: map['workspace_id'] as String,
      title: map['title'] as String,
      category: map['category'] as String,
      startsAt: DateTime.parse(map['starts_at'] as String),
      endsAt: maybeDate('ends_at'),
      venueTimezone: map['venue_timezone'] as String?,
      status: map['status'] as String,
      source: map['source'] as String,
      notes: map['notes'] as String?,
      coverImageUrl: map['cover_image_url'] as String?,
      venueImageUrl: map['venue_image_url'] as String?,
      venueAddress: map['venue_address'] as String?,
      departureAt: maybeDate('departure_at'),
      version: map['version'] as int,
      updatedAt: DateTime.parse(map['updated_at'] as String),
      deletedAt: maybeDate('deleted_at'),
    );
  }

  final String id;
  final String workspaceId;
  final String title;
  final String category;
  final DateTime startsAt;
  final DateTime? endsAt;
  final String? venueTimezone;
  final String status;
  final String source;
  final String? notes;
  final String? coverImageUrl;
  final String? venueImageUrl;
  final String? venueAddress;
  final DateTime? departureAt;
  final int version;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  drift.CachedEventsCompanion toCompanion() {
    return drift.CachedEventsCompanion.insert(
      id: id,
      workspaceId: workspaceId,
      title: title,
      category: category,
      startsAt: startsAt,
      endsAt: Value<DateTime?>(endsAt),
      venueTimezone: Value<String?>(venueTimezone),
      status: status,
      source: source,
      notes: Value<String?>(notes),
      coverImageUrl: Value<String?>(coverImageUrl),
      venueImageUrl: Value<String?>(venueImageUrl),
      venueAddress: Value<String?>(venueAddress),
      departureAt: Value<DateTime?>(departureAt),
      version: version,
      updatedAt: updatedAt,
      deletedAt: Value<DateTime?>(deletedAt),
      cachedAt: DateTime.now().toUtc(),
    );
  }
}

class TicketDto {
  const TicketDto({
    required this.id,
    required this.eventId,
    required this.workspaceId,
    required this.mimeType,
    required this.originalFilename,
    required this.sizeBytes,
    required this.hashSha256,
    required this.version,
    required this.updatedAt,
    required this.deletedAt,
  });

  factory TicketDto.fromMap(Map<String, dynamic> map) {
    DateTime? maybeDate(String key) {
      final Object? value = map[key];
      if (value == null) {
        return null;
      }
      return DateTime.parse(value as String);
    }

    return TicketDto(
      id: map['id'] as String,
      eventId: map['event_id'] as String,
      workspaceId: map['workspace_id'] as String,
      mimeType: map['mime_type'] as String,
      originalFilename: map['original_filename'] as String?,
      sizeBytes: map['size_bytes'] as int?,
      hashSha256: map['hash_sha256'] as String?,
      version: map['version'] as int,
      updatedAt: DateTime.parse(map['updated_at'] as String),
      deletedAt: maybeDate('deleted_at'),
    );
  }

  final String id;
  final String eventId;
  final String workspaceId;
  final String mimeType;
  final String? originalFilename;
  final int? sizeBytes;
  final String? hashSha256;
  final int version;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  drift.CachedTicketsCompanion toCompanion() {
    return drift.CachedTicketsCompanion.insert(
      id: id,
      eventId: eventId,
      workspaceId: workspaceId,
      mimeType: mimeType,
      originalFilename: Value<String?>(originalFilename),
      sizeBytes: Value<int?>(sizeBytes),
      hashSha256: Value<String?>(hashSha256),
      version: version,
      updatedAt: updatedAt,
      deletedAt: Value<DateTime?>(deletedAt),
      cachedAt: DateTime.now().toUtc(),
    );
  }
}
