import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/storage/token_store.dart';

// Regression guards for the silent-logout bug (2026-06-03): the UI and the
// background WorkManager isolate raced their token rotations, the server's
// reuse detection burned the token family, and the old interceptor cleared
// the store on ANY refresh failure — including plain network errors. The
// device then 401-ed forever without ever attempting another refresh.
//
// Pinned contracts:
//  * concurrent 401s share ONE rotation (single refresh request on the wire)
//  * a transient refresh failure (5xx/timeout) keeps the stored tokens
//  * only a definitive 401 from the refresh endpoint clears the store

class _MemorySecureStorage implements FlutterSecureStorage {
  final Map<String, String> values = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #readAll) {
      return Future<Map<String, String>>.value(Map<String, String>.of(values));
    }
    if (invocation.memberName == #write) {
      values[invocation.namedArguments[#key] as String] =
          invocation.namedArguments[#value] as String;
      return Future<void>.value();
    }
    if (invocation.memberName == #delete) {
      values.remove(invocation.namedArguments[#key] as String);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

enum _RefreshBehaviour { rotate, serverError, reject, supersededByPeer }

void main() {
  late HttpServer server;
  late _MemorySecureStorage storage;
  late TokenStore tokenStore;
  late KpClient client;
  late Directory lockDir;

  int refreshCalls = 0;
  _RefreshBehaviour refreshBehaviour = _RefreshBehaviour.rotate;

  Future<void> writeInitialPair() => tokenStore.write(
    TokenPair(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
      accessExpiresAt: DateTime.now().add(const Duration(hours: 1)),
      refreshExpiresAt: DateTime.now().add(const Duration(days: 30)),
    ),
  );

  setUp(() async {
    refreshCalls = 0;
    refreshBehaviour = _RefreshBehaviour.rotate;
    storage = _MemorySecureStorage();
    tokenStore = TokenStore(storage);
    lockDir = await Directory.systemTemp.createTemp('kp-refresh-lock');

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      if (req.uri.path == '/v1/auth/refresh') {
        refreshCalls += 1;
        // Widen the race window: a second 401 arriving mid-rotation must
        // join this refresh, not start its own.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        switch (refreshBehaviour) {
          case _RefreshBehaviour.rotate:
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode(<String, String>{
                  'access_token': 'new-access',
                  'refresh_token': 'new-refresh',
                  'access_expires_at': DateTime.now()
                      .add(const Duration(hours: 1))
                      .toIso8601String(),
                  'refresh_expires_at': DateTime.now()
                      .add(const Duration(days: 30))
                      .toIso8601String(),
                }),
              );
          case _RefreshBehaviour.serverError:
            req.response.statusCode = 500;
          case _RefreshBehaviour.reject:
            req.response.statusCode = 401;
          case _RefreshBehaviour.supersededByPeer:
            // Another isolate won the rotation moments ago: its successor
            // pair is already persisted, and the server rejects our stale
            // token within the reuse-grace window without burning the
            // family.
            await tokenStore.write(
              TokenPair(
                accessToken: 'new-access',
                refreshToken: 'new-refresh',
                accessExpiresAt: DateTime.now().add(const Duration(hours: 1)),
                refreshExpiresAt: DateTime.now().add(const Duration(days: 30)),
              ),
            );
            req.response.statusCode = 401;
        }
      } else {
        final String? auth = req.headers.value('authorization');
        if (auth == 'Bearer new-access') {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('{"ok": true}');
        } else {
          req.response.statusCode = 401;
        }
      }
      await req.response.close();
    });

    client = KpClient(
      tokenStore,
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}')),
      lockDir: () async => lockDir.path,
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await lockDir.delete(recursive: true);
  });

  test(
    'concurrent 401s share a single rotation and both retries succeed',
    () async {
      await writeInitialPair();

      final List<Response<dynamic>> responses = await Future.wait(
        <Future<Response<dynamic>>>[
          client.dio.get<dynamic>('/v1/sync'),
          client.dio.get<dynamic>('/v1/sync'),
        ],
      );

      expect(refreshCalls, 1);
      expect(responses.map((r) => r.statusCode), everyElement(200));
      final TokenPair? stored = await tokenStore.read();
      expect(stored?.accessToken, 'new-access');
      expect(stored?.refreshToken, 'new-refresh');
    },
  );

  test('transient refresh failure keeps the stored tokens', () async {
    await writeInitialPair();
    refreshBehaviour = _RefreshBehaviour.serverError;

    await expectLater(
      client.dio.get<dynamic>('/v1/sync'),
      throwsA(isA<DioException>()),
    );

    final TokenPair? stored = await tokenStore.read();
    expect(stored, isNotNull);
    expect(stored?.refreshToken, 'old-refresh');
  });

  test('definitive refresh rejection clears the store', () async {
    await writeInitialPair();
    refreshBehaviour = _RefreshBehaviour.reject;

    await expectLater(
      client.dio.get<dynamic>('/v1/sync'),
      throwsA(isA<DioException>()),
    );

    expect(await tokenStore.read(), isNull);
  });

  test(
    'superseded rotation adopts the peer pair instead of clearing',
    () async {
      await writeInitialPair();
      refreshBehaviour = _RefreshBehaviour.supersededByPeer;

      final Response<dynamic> response = await client.dio.get<dynamic>(
        '/v1/sync',
      );

      expect(response.statusCode, 200);
      final TokenPair? stored = await tokenStore.read();
      expect(stored?.refreshToken, 'new-refresh');
    },
  );
}
