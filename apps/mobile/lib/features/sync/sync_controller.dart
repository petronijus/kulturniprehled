import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/costs/cost_dto.dart';
import 'package:kp_mobile/features/events/event_dto.dart';
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
        cursor = body['next_seq'] as int;
        await db.writeCursor(cursor);
        if (body['has_more'] != true) {
          break;
        }
      }
      state = SyncState(lastSyncedAt: DateTime.now());
    } on DioException catch (e) {
      state = state.copyWith(
        isSyncing: false,
        error: e.response?.data?.toString() ?? e.message ?? 'sync failed',
      );
    } catch (e) {
      state = state.copyWith(isSyncing: false, error: e.toString());
    }
  }

  Future<void> _applyChange(Map<String, dynamic> entry) async {
    final String entityType = entry['entity_type'] as String;
    final Map<String, dynamic> payload =
        entry['payload'] as Map<String, dynamic>;
    final KpDatabase db = ref.read(kpDatabaseProvider);
    if (entityType == 'event') {
      final EventDto event = EventDto.fromMap(payload);
      await db.upsertEvent(event.toCompanion());
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
    // Unknown entity types are dropped silently — they will land on the
    // next schema bump that adds support for them.
  }
}

final NotifierProvider<SyncController, SyncState> syncControllerProvider =
    NotifierProvider<SyncController, SyncState>(SyncController.new);
