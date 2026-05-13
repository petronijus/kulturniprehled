import 'dart:convert';

import 'package:dio/dio.dart'
    show Dio, DioException, DioExceptionType, RequestOptions;
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/data/storage/token_store.dart';
import 'package:kp_mobile/features/outbox/outbox_controller.dart';

import 'helpers/in_memory_db.dart';

class _NullTokenStore extends TokenStore {
  _NullTokenStore() : super();
  @override
  Future<TokenPair?> read() async => null;
  @override
  Future<void> write(TokenPair pair) async {}
  @override
  Future<void> clear() async {}
}

class _FakeKpClient extends KpClient {
  _FakeKpClient(this._handler) : super(_NullTokenStore(), dio: Dio());

  final Future<Map<String, dynamic>> Function(List<Map<String, Object?>>)
  _handler;

  @override
  Future<Map<String, dynamic>> applyOperations(
    List<Map<String, Object?>> operations,
  ) => _handler(operations);
}

Future<void> _seedPendingUpdate(KpDatabase db, String opId) async {
  await db.insertPendingOp(
    PendingOpsCompanion.insert(
      opId: opId,
      entityType: 'event',
      op: 'update',
      entityId: const Value<String?>('evt-1'),
      baseVersion: const Value<int?>(1),
      payloadJson: jsonEncode(<String, Object?>{'status': 'attended'}),
      createdAt: DateTime.now(),
    ),
  );
}

void main() {
  test('pushPending sends batch and clears applied rows', () async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    await _seedPendingUpdate(db, 'op-1');

    final List<List<Map<String, Object?>>> seen =
        <List<Map<String, Object?>>>[];
    final KpClient client = _FakeKpClient((ops) async {
      seen.add(ops);
      return <String, dynamic>{
        'results': <Map<String, Object?>>[
          for (final Map<String, Object?> op in ops)
            <String, Object?>{
              'op_id': op['op_id'],
              'status': 'applied',
              'entity_id': op['entity_id'],
              'version': 2,
              'seq': 42,
            },
        ],
      };
    });

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        kpDatabaseProvider.overrideWithValue(db),
        kpClientProvider.overrideWith((ref) => client),
      ],
    );
    addTearDown(container.dispose);

    await container.read(outboxControllerProvider.notifier).pushPending();

    expect(await db.countPending(), equals(0));
    expect(seen, hasLength(1));
    expect(seen.first, hasLength(1));
    expect(seen.first.first['op_id'], equals('op-1'));
    expect(seen.first.first['base_version'], equals(1));
  });

  test('conflict result surfaces on stream and op stays pending', () async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    await _seedPendingUpdate(db, 'op-2');

    final KpClient client = _FakeKpClient((ops) async {
      return <String, dynamic>{
        'results': <Map<String, Object?>>[
          <String, Object?>{
            'op_id': ops.first['op_id'],
            'status': 'conflict',
            'entity_id': 'evt-1',
            'current_version': 5,
          },
        ],
      };
    });

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        kpDatabaseProvider.overrideWithValue(db),
        kpClientProvider.overrideWith((ref) => client),
      ],
    );
    addTearDown(container.dispose);

    final OutboxController outbox = container.read(
      outboxControllerProvider.notifier,
    );
    final Future<OutboxConflict> conflictFuture = outbox.conflicts.first
        .timeout(const Duration(seconds: 2));
    await outbox.pushPending();

    final OutboxConflict conflict = await conflictFuture;
    expect(conflict.entityId, equals('evt-1'));
    expect(conflict.currentVersion, equals(5));
    expect(await db.countPending(), equals(1));
  });

  test('network failure leaves op pending with attempts++', () async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    await _seedPendingUpdate(db, 'op-3');

    final KpClient client = _FakeKpClient((ops) async {
      throw DioException(
        requestOptions: RequestOptions(path: '/v1/sync/apply'),
        message: 'connection refused',
        type: DioExceptionType.connectionError,
      );
    });

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        kpDatabaseProvider.overrideWithValue(db),
        kpClientProvider.overrideWith((ref) => client),
      ],
    );
    addTearDown(container.dispose);

    await container.read(outboxControllerProvider.notifier).pushPending();

    final List<PendingOpRow> remaining = await db.readPendingBatch();
    expect(remaining, hasLength(1));
    expect(remaining.single.attempts, equals(1));
    expect(remaining.single.lastError, contains('connection'));
  });

  test('queueEventUpdate inserts a pending row immediately', () async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    final KpClient client = _FakeKpClient((ops) async {
      return <String, dynamic>{'results': <Map<String, Object?>>[]};
    });
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        kpDatabaseProvider.overrideWithValue(db),
        kpClientProvider.overrideWith((ref) => client),
      ],
    );
    addTearDown(container.dispose);

    final OutboxController outbox = container.read(
      outboxControllerProvider.notifier,
    );
    final String opId = await outbox.queueEventUpdate(
      entityId: 'evt-x',
      baseVersion: 7,
      fields: <String, Object?>{'notes': 'hi'},
    );
    expect(opId, isNotEmpty);
    final List<PendingOpRow> rows = await db.readPendingBatch();
    expect(rows.map((r) => r.opId), contains(opId));
  });
}
