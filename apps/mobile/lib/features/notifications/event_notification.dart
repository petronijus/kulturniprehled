// An event notification as the server sends it through /v1/sync. The server
// decides what is worth telling (a new event, a changed venue or programme,
// a member's manual request); the phone only renders and shows it. Keep the
// map shape aligned with `serialize_notification` in
// apps/api/src/kp_api/sync/changelog.py.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:intl/intl.dart';

import 'package:kp_mobile/data/drift/database.dart' as drift;

class EventNotificationDto {
  const EventNotificationDto({
    required this.id,
    required this.workspaceId,
    required this.eventId,
    required this.kind,
    required this.changes,
    required this.message,
    required this.createdBy,
    required this.deliverAfter,
    required this.version,
    required this.updatedAt,
    required this.deletedAt,
  });

  factory EventNotificationDto.fromMap(Map<String, dynamic> map) {
    final Object? deletedAt = map['deleted_at'];
    return EventNotificationDto(
      id: map['id'] as String,
      workspaceId: map['workspace_id'] as String,
      eventId: map['event_id'] as String,
      kind: map['kind'] as String,
      changes: (map['changes'] as List<dynamic>).cast<String>(),
      message: map['message'] as String?,
      createdBy: map['created_by'] as String,
      deliverAfter: DateTime.parse(map['deliver_after'] as String),
      version: map['version'] as int,
      updatedAt: DateTime.parse(map['updated_at'] as String),
      deletedAt: deletedAt == null ? null : DateTime.parse(deletedAt as String),
    );
  }

  final String id;
  final String workspaceId;
  final String eventId;
  final String kind;
  final List<String> changes;
  final String? message;
  final String createdBy;
  final DateTime deliverAfter;
  final int version;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  /// Leaves the local-only columns (`shownVersion`, `attempts`,
  /// `lastError`) absent, so the upsert of a newer version keeps them.
  drift.CachedNotificationsCompanion toCompanion() {
    return drift.CachedNotificationsCompanion.insert(
      id: id,
      workspaceId: workspaceId,
      eventId: eventId,
      kind: kind,
      changesJson: jsonEncode(changes),
      message: Value<String?>(message),
      createdBy: createdBy,
      deliverAfter: deliverAfter,
      version: version,
      updatedAt: updatedAt,
      deletedAt: Value<DateTime?>(deletedAt),
      cachedAt: DateTime.now().toUtc(),
    );
  }
}

class NotificationText {
  const NotificationText({required this.title, required this.body});

  final String title;
  final String body;
}

/// Renders [notification] about [event] the way the phone shows it. The
/// event is read at delivery time, not when the notification was created,
/// so the text and cover are the event's current ones. Needs the 'cs'
/// locale data loaded (`initializeDateFormatting('cs')`).
NotificationText renderEventNotification(
  drift.CachedNotificationRow notification,
  drift.CachedEventRow event,
) {
  final List<String> changes =
      (jsonDecode(notification.changesJson) as List<dynamic>).cast<String>();
  final bool created = notification.kind == 'event_created';
  final String title = created
      ? 'Nová akce: ${event.title}'
      : changes.isNotEmpty || notification.kind == 'event_changed'
      ? 'Změna: ${event.title}'
      : event.title;

  final String? venue = _nonBlank(event.venueAddress);
  final List<String> lines = <String>[
    if (_nonBlank(notification.message) case final String message) message,
    if (!created && changes.contains('venue'))
      venue == null ? 'Místo odstraněno' : 'Nové místo: $venue',
    if (!created && changes.contains('program')) 'Upravený program',
  ];
  final String when = _capitalize(
    DateFormat("EEEE d.M. 'v' HH:mm", 'cs').format(event.startsAt.toLocal()),
  );
  final bool venueAlreadySaid = !created && changes.contains('venue');
  lines.add(venue == null || venueAlreadySaid ? when : '$when — $venue');
  return NotificationText(title: title, body: lines.join('\n'));
}

String? _nonBlank(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _capitalize(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
