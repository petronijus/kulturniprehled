import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/storage/token_store.dart';
import 'package:kp_mobile/features/stats/stats_replay_provider.dart';
import 'package:kp_mobile/features/stats/stats_screen.dart';

// Regression guard for the stale-stats-error bug (2026-06-06): the shell
// keeps tab states alive, so a single failed /v1/stats load (e.g. during
// an auth hiccup) stuck around as a permanent error screen. Re-entering
// the tab bumps [statsReplayProvider]; that must also retry the load.

class _NoopSecureStorage implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #readAll) {
      return Future<Map<String, String>>.value(<String, String>{});
    }
    return Future<void>.value();
  }
}

/// Fails the first request with a 500, serves stats JSON afterwards.
class _FailOnceAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    if (calls == 1) {
      return ResponseBody.fromString('boom', 500);
    }
    return ResponseBody.fromString(
      '{"total_events":2,"total_cost_cents":0,'
      '"by_category":[],"by_month":[],"top_venues":[]}',
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[ContentType.json.mimeType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets('re-entering the stats tab retries a failed load', (
    WidgetTester tester,
  ) async {
    final _FailOnceAdapter adapter = _FailOnceAdapter();
    final Dio dio = Dio(BaseOptions(baseUrl: 'http://stub'))
      ..httpClientAdapter = adapter;
    final KpClient client = KpClient(
      TokenStore(_NoopSecureStorage()),
      dio: dio,
      lockDir: () async => Directory.systemTemp.path,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[kpClientProvider.overrideWith((ref) => client)],
        child: const MaterialApp(home: StatsScreen()),
      ),
    );

    // First load fails (500) → error UI with the retry affordance.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Zkusit znovu'), findsOneWidget);
    expect(adapter.calls, 1);

    // Re-entering the tab bumps the replay provider — that must retry.
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(StatsScreen)),
    );
    container.read(statsReplayProvider.notifier).state++;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(adapter.calls, 2);
    expect(find.text('Zkusit znovu'), findsNothing);
  });
}
