import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';

// Lightweight server-status probe. Pings /healthz every 30 s; the AppBar
// of the agenda screen flips a tiny cloud-off icon when the most recent
// ping failed (auth interceptor doesn't get involved — /healthz is open).
//
// Not a heartbeat — just enough to give the user a hint when the API is
// down and writes will queue in the outbox.

enum ServerHealth { unknown, ok, unreachable }

class ServerStatusController extends Notifier<ServerHealth> {
  Timer? _timer;

  @override
  ServerHealth build() {
    ref.onDispose(() => _timer?.cancel());
    Future<void>.microtask(_probe);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _probe());
    return ServerHealth.unknown;
  }

  Future<void> _probe() async {
    final KpClient client = ref.read(kpClientProvider);
    try {
      // Use a short timeout so a hung connection doesn't park us in
      // "unknown" forever.
      final Response<dynamic> response = await client.dio.get<dynamic>(
        '/healthz',
        options: Options(
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      state = response.statusCode == 200
          ? ServerHealth.ok
          : ServerHealth.unreachable;
    } catch (_) {
      state = ServerHealth.unreachable;
    }
  }
}

final NotifierProvider<ServerStatusController, ServerHealth>
serverStatusProvider = NotifierProvider<ServerStatusController, ServerHealth>(
  ServerStatusController.new,
);
