import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/costs/cost_dto.dart';
import 'package:kp_mobile/features/events/event_dto.dart';
import 'package:kp_mobile/features/notifications/event_notification.dart';
import 'package:kp_mobile/features/notifications/notification_service.dart';
import 'package:kp_mobile/features/sync/offline_cache_service.dart';
import 'package:kp_mobile/features/watchlist/watchlist_dto.dart';

// Pulls /v1/sync since the last cursor and feeds change_log entries into
// the drift cache. Designed to be idempotent and quick — long, full-page
// sync is fine the first time, after that the cursor keeps each call to a
// minute's worth of changes.

class SyncState {
  const SyncState({this.isSyncing = false, this.lastSyncedAt, this.error});

  final bool isSyncing;
  final DateTime? lastSyncedAt;
  final String? error;

  SyncState copyWith({
    bool? isSyncing,
    DateTime? lastSyncedAt,
    String? error,
    bool clearError = false,
  }) {
    return SyncState(
      isSyncing: isSyncing ?? this.isSyncing,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SyncController extends Notifier<SyncState> {
  @override
  SyncState build() => const SyncState();

  Future<void> pullChanges({int batchSize = 500}) async {
    if (state.isSyncing) {
      return;
    }
    state = state.copyWith(isSyncing: true, clearError: true);
    final KpDatabase db = ref.read(kpDatabaseProvider);
    final KpClient client = ref.read(kpClientProvider);

    try {
      int cursor = await db.readCursor() ?? 0;
      final bool isFirstSync = cursor == 0;
      DateTime serverNow = DateTime.now().toUtc();
      while (true) {
        final Response<dynamic> response = await client.dio.get<dynamic>(
          '/v1/sync',
          queryParameters: <String, dynamic>{
            'since': cursor,
            'limit': batchSize,
          },
        );
        final Map<String, dynamic> body =
            response.data! as Map<String, dynamic>;
        final List<dynamic> changes =
            (body['changes'] as List<dynamic>? ?? const <dynamic>[]);
        for (final dynamic entry in changes) {
          await _applyChange(entry as Map<String, dynamic>);
        }
        final Object? serverTime = body['server_time'];
        if (serverTime is String) {
          serverNow = DateTime.parse(serverTime);
        }
        cursor = body['next_seq'] as int;
        await db.writeCursor(cursor);
        if (body['has_more'] != true) {
          break;
        }
      }
      state = SyncState(lastSyncedAt: DateTime.now());
      if (isFirstSync) {
        // A fresh install must not replay the workspace's whole history.
        await db.markDueNotificationsShown(serverNow);
      } else {
        await _deliverDueNotifications(db, serverNow);
      }
      // Cache images + ticket binaries off the UI thread. We don't await
      // so a slow download (or a sticky MinIO) doesn't keep the agenda
      // spinner up; the next render will see whichever files have landed.
      unawaited(ref.read(offlineCacheServiceProvider).refresh());
    } on DioException catch (e) {
      debugPrint(
        'kp-sync: DioException ${e.response?.statusCode} ${e.message}',
      );
      state = state.copyWith(
        isSyncing: false,
        error: e.response?.data?.toString() ?? e.message ?? 'sync failed',
      );
    } catch (e, st) {
      debugPrint('kp-sync: pullChanges failed: $e\n$st');
      state = state.copyWith(isSyncing: false, error: e.toString());
    }
  }

  /// Shows every notification that is due on the server clock and whose
  /// current version this device has not shown. A failed show is recorded
  /// on the row (and sent to Sentry) and retried on the next sync. One for a
  /// deleted event, or overdue by more than [_staleAfter] (the phone was
  /// offline for days, or the show kept failing), is dropped — logged with
  /// its last error, if it had one.
  Future<void> _deliverDueNotifications(
    KpDatabase db,
    DateTime serverNow,
  ) async {
    final NotificationService notifs = ref.read(notificationServiceProvider);
    for (final CachedNotificationRow notification in await db.dueNotifications(
      serverNow,
    )) {
      final CachedEventRow? event = await db.findEvent(notification.eventId);
      final bool stale =
          serverNow.difference(notification.deliverAfter) > _staleAfter;
      if (event == null || event.deletedAt != null || stale) {
        final String reason = event == null
            ? 'event missing'
            : event.deletedAt != null
            ? 'event deleted'
            : notification.lastError != null
            ? 'failed ${notification.attempts}x, last: ${notification.lastError}'
            : 'overdue by more than $_staleAfter';
        debugPrint(
          'kp-notif: dropping notification ${notification.id} ($reason)',
        );
        await db.markNotificationShown(notification.id, notification.version);
        continue;
      }
      // A single failed notification must not abort the rest of the sync —
      // and the error must surface, not vanish into pullChanges' own catch
      // (that swallow hid a LocaleDataException in the background isolate
      // for a long time).
      try {
        await notifs.showEventNotification(notification, event);
        await db.markNotificationShown(notification.id, notification.version);
      } catch (e, st) {
        debugPrint(
          'kp-notif: showing notification ${notification.id} failed: $e\n$st',
        );
        await db.recordNotificationFailure(notification.id, e.toString());
        await Sentry.captureException(e, stackTrace: st);
      }
    }
  }

  static const Duration _staleAfter = Duration(hours: 24);

  Future<void> _applyChange(Map<String, dynamic> entry) async {
    final String entityType = entry['entity_type'] as String;
    final Map<String, dynamic> payload =
        entry['payload'] as Map<String, dynamic>;
    final KpDatabase db = ref.read(kpDatabaseProvider);
    if (entityType == 'event') {
      final EventDto event = EventDto.fromMap(payload);
      await db.upsertEvent(event.toCompanion());
    } else if (entityType == 'notification') {
      final EventNotificationDto notification = EventNotificationDto.fromMap(
        payload,
      );
      await db.upsertNotification(notification.toCompanion());
    } else if (entityType == 'ticket') {
      final TicketDto ticket = TicketDto.fromMap(payload);
      await db.upsertTicket(ticket.toCompanion());
    } else if (entityType == 'cost') {
      final CostDto cost = CostDto.fromMap(payload);
      await db.upsertCost(cost.toCompanion());
    } else if (entityType == 'watchlist_item') {
      final WatchlistItemDto item = WatchlistItemDto.fromMap(payload);
      await db.upsertWatchlistItem(item.toCompanion());
    }
  }
}

final NotifierProvider<SyncController, SyncState> syncControllerProvider =
    NotifierProvider<SyncController, SyncState>(SyncController.new);
