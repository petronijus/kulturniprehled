import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show DioException;
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/drift/database.dart';

// Offline-first outbox.
//
// Mutations (event updates, deletes) are *always* persisted to the
// pending_ops drift table before any network attempt. A pushPending() pass
// then drains the queue via POST /v1/sync/apply, walking each result:
//
//   applied   → row deleted, conflict listener informed of new version
//   conflict  → row stays pending (UI prompts the user to resolve), but
//               the controller emits an OutboxConflict so the UI can show
//               the resolution dialog the next time the user is on this
//               event
//   invalid / not_found → row deleted, treated as terminal failure
//   network error → row stays pending, attempts++ , retried later
//
// The controller never blocks the UI: callers fire-and-forget
// `pushPending()`, watch `pendingCountProvider` for badge counts, and
// listen to `outboxConflictStreamProvider` for resolution prompts.

class OutboxConflict {
  const OutboxConflict({
    required this.opId,
    required this.entityType,
    required this.entityId,
    required this.attemptedPayload,
    required this.currentVersion,
  });

  final String opId;
  final String entityType;
  final String entityId;
  final Map<String, Object?> attemptedPayload;
  final int currentVersion;
}

class OutboxController extends Notifier<bool> {
  // State holds isFlushing flag. Conflicts go through a side-channel stream
  // so a screen mounted after the conflict happened can still pick it up.
  @override
  bool build() => false;

  final StreamController<OutboxConflict> _conflicts =
      StreamController<OutboxConflict>.broadcast();

  Stream<OutboxConflict> get conflicts => _conflicts.stream;

  Future<String> queueEventUpdate({
    required String entityId,
    required int baseVersion,
    required Map<String, Object?> fields,
  }) async {
    final String opId = const Uuid().v4();
    final KpDatabase db = ref.read(kpDatabaseProvider);
    await db.insertPendingOp(
      PendingOpsCompanion.insert(
        opId: opId,
        entityType: 'event',
        op: 'update',
        entityId: Value<String?>(entityId),
        baseVersion: Value<int?>(baseVersion),
        payloadJson: jsonEncode(fields),
        createdAt: DateTime.now(),
      ),
    );
    // Fire-and-forget — caller will see pendingCount go up immediately, and
    // the network attempt happens in the background.
    unawaited(pushPending());
    return opId;
  }

  Future<void> queueEventDelete({required String entityId}) async {
    final String opId = const Uuid().v4();
    final KpDatabase db = ref.read(kpDatabaseProvider);
    await db.insertPendingOp(
      PendingOpsCompanion.insert(
        opId: opId,
        entityType: 'event',
        op: 'delete',
        entityId: Value<String?>(entityId),
        baseVersion: const Value<int?>(null),
        payloadJson: '{}',
        createdAt: DateTime.now(),
      ),
    );
    unawaited(pushPending());
  }

  Future<void> pushPending() async {
    if (state) {
      return;
    }
    state = true;
    try {
      final KpDatabase db = ref.read(kpDatabaseProvider);
      final KpClient client = ref.read(kpClientProvider);
      while (true) {
        final List<PendingOpRow> batch = await db.readPendingBatch();
        if (batch.isEmpty) {
          break;
        }
        final List<Map<String, Object?>> operations = batch
            .map(
              (op) => <String, Object?>{
                'op_id': op.opId,
                'entity': op.entityType,
                'op': op.op,
                if (op.entityId != null) 'entity_id': op.entityId,
                if (op.baseVersion != null) 'base_version': op.baseVersion,
                'payload': jsonDecode(op.payloadJson),
              },
            )
            .toList();

        try {
          final Map<String, dynamic> body = await client.applyOperations(
            operations,
          );
          final List<dynamic> results =
              body['results'] as List<dynamic>? ?? const <dynamic>[];
          for (int i = 0; i < results.length; i++) {
            final Map<String, dynamic> result =
                results[i] as Map<String, dynamic>;
            final PendingOpRow op = batch[i];
            await _applyResult(op, result);
          }
        } on DioException catch (e) {
          // Whole-batch network failure: bump attempts on every row, leave
          // them pending. Push again on next trigger (manual refresh, app
          // foreground, etc.).
          for (final PendingOpRow op in batch) {
            await db.markPendingError(op.opId, e.message ?? 'network error');
          }
          break;
        }

        // If the batch was smaller than the limit we are done.
        if (batch.length < 50) {
          break;
        }
      }
    } finally {
      state = false;
    }
  }

  Future<void> _applyResult(
    PendingOpRow op,
    Map<String, dynamic> result,
  ) async {
    final KpDatabase db = ref.read(kpDatabaseProvider);
    final String status = result['status'] as String;
    if (status == 'applied') {
      await db.markPendingApplied(op.opId);
      await db.deletePending(op.opId);
      return;
    }
    if (status == 'conflict') {
      await db.markPendingError(op.opId, 'conflict');
      _conflicts.add(
        OutboxConflict(
          opId: op.opId,
          entityType: op.entityType,
          entityId: op.entityId ?? '',
          attemptedPayload: jsonDecode(op.payloadJson) as Map<String, Object?>,
          currentVersion: result['current_version'] as int,
        ),
      );
      return;
    }
    // not_found / invalid / forbidden — drop the op, log the error. The UI
    // will eventually reconcile via the next /v1/sync pull.
    await db.markPendingError(op.opId, status);
    await db.deletePending(op.opId);
  }

  Future<void> discardPending(String opId) async {
    final KpDatabase db = ref.read(kpDatabaseProvider);
    await db.deletePending(opId);
  }

  Future<void> requeueWithFreshBaseVersion({
    required String opId,
    required int baseVersion,
  }) async {
    // The user chose "Keep mine" — discard the old row and queue a fresh one
    // with the latest base_version. Same op_id is fine because we deleted it.
    final KpDatabase db = ref.read(kpDatabaseProvider);
    final List<PendingOpRow> rows = await db.readPendingBatch(limit: 200);
    final PendingOpRow? row = rows
        .where((r) => r.opId == opId)
        .cast<PendingOpRow?>()
        .firstOrNull;
    if (row == null) {
      return;
    }
    await db.deletePending(opId);
    final String newOpId = const Uuid().v4();
    await db.insertPendingOp(
      PendingOpsCompanion.insert(
        opId: newOpId,
        entityType: row.entityType,
        op: row.op,
        entityId: Value<String?>(row.entityId),
        baseVersion: Value<int?>(baseVersion),
        payloadJson: row.payloadJson,
        createdAt: DateTime.now(),
      ),
    );
    unawaited(pushPending());
  }
}

final NotifierProvider<OutboxController, bool> outboxControllerProvider =
    NotifierProvider<OutboxController, bool>(OutboxController.new);

final StreamProvider<int> pendingCountProvider = StreamProvider<int>(
  (ref) => ref.read(kpDatabaseProvider).watchPendingCount(),
);

final StreamProvider<OutboxConflict> outboxConflictStreamProvider =
    StreamProvider<OutboxConflict>(
      (ref) => ref.read(outboxControllerProvider.notifier).conflicts,
    );

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
