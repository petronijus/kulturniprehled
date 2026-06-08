import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:kp_mobile/core/config.dart';
import 'package:kp_mobile/data/storage/token_store.dart';

// Dio-based KP API client.
//
// The auth interceptor injects the bearer token on every request, and
// transparently refreshes the access token on the first 401 with a fresh
// refresh-token rotation. If the refresh itself fails the client clears the
// token store so the router redirects to /login on the next frame.
//
// Refresh discipline (hard-learned 2026-06-03, see docs/handover.md): the
// UI isolate and the WorkManager background isolate each own a KpClient,
// and two concurrent rotations of the same refresh token trip the server's
// reuse detection — which burns the whole token family and silently logs
// the device out. Rotation therefore runs inside an OS file lock shared by
// every isolate, re-checks the token store after acquiring it (the other
// isolate may have already rotated), and only clears the store on a
// definitive 401/403 from the refresh endpoint — never on a transient
// network error.

class TokenRefreshFailure implements Exception {
  const TokenRefreshFailure();
  @override
  String toString() => 'token refresh failed';
}

class KpClient {
  KpClient(this._tokenStore, {Dio? dio, Future<String> Function()? lockDir})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: AppConfig.apiBaseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              headers: <String, String>{'Accept': 'application/json'},
            ),
          ),
      _lockDir =
          lockDir ??
          (() async => (await getApplicationSupportDirectory()).path) {
    _dio.interceptors.add(_AuthInterceptor(this));
  }

  final Dio _dio;
  final TokenStore _tokenStore;
  final Future<String> Function() _lockDir;

  Dio get dio => _dio;

  /// Typed wrapper around POST /v1/sync/apply. Encapsulates the JSON
  /// envelope so the outbox controller never has to touch `Response`
  /// shapes — and tests can override this method without standing up a
  /// full Dio adapter.
  Future<Map<String, dynamic>> applyOperations(
    List<Map<String, Object?>> operations,
  ) async {
    final Response<dynamic> response = await _dio.post<dynamic>(
      '/v1/sync/apply',
      data: <String, Object?>{'operations': operations},
    );
    final dynamic raw = response.data;
    if (raw is String) {
      return jsonDecode(raw) as Map<String, dynamic>;
    }
    return raw as Map<String, dynamic>;
  }

  /// Rotates the refresh token and returns the new pair, or the pair another
  /// isolate already rotated to while we were waiting for the lock.
  ///
  /// [staleAccessToken] is the bearer that just got the 401 — if the stored
  /// pair no longer matches it, a concurrent isolate has already refreshed
  /// and rotating again would only risk tripping reuse detection.
  Future<TokenPair?> _refresh({String? staleAccessToken}) async {
    final RandomAccessFile lock = await _acquireRefreshLock();
    try {
      final TokenPair? current = await _tokenStore.read();
      if (current == null) {
        return null;
      }
      if (staleAccessToken != null && current.accessToken != staleAccessToken) {
        return current;
      }
      try {
        final Response<dynamic> response =
            await Dio(BaseOptions(baseUrl: _dio.options.baseUrl)).post<dynamic>(
              '/v1/auth/refresh',
              data: <String, String>{'refresh_token': current.refreshToken},
            );
        final Map<String, dynamic> body =
            response.data! as Map<String, dynamic>;
        final TokenPair pair = TokenPair(
          accessToken: body['access_token'] as String,
          refreshToken: body['refresh_token'] as String,
          accessExpiresAt: DateTime.parse(body['access_expires_at'] as String),
          refreshExpiresAt: DateTime.parse(
            body['refresh_expires_at'] as String,
          ),
        );
        await _tokenStore.write(pair);
        return pair;
      } on DioException catch (e) {
        final int? status = e.response?.statusCode;
        if (status == 401 || status == 403) {
          // The rejection may be a benign "refresh superseded": the file
          // lock is fcntl-based and does NOT exclude two isolates of the
          // same process, so the UI and background isolates can still
          // race one rotation. The loser's token is rejected within the
          // server's grace window while the winner has already persisted
          // the successor pair — clearing the store here would throw that
          // pair away and silently log the device out (2026-06-06).
          // Only treat the rejection as fatal if the store still holds
          // exactly the token the server refused.
          final TokenPair? latest = await _tokenStore.read();
          if (latest != null && latest.refreshToken != current.refreshToken) {
            return latest;
          }
          await _tokenStore.clear();
        }
        // Anything else (timeout, DNS, 5xx) is transient: keep the tokens
        // and let the next sync retry.
        return null;
      }
    } finally {
      try {
        await lock.unlock();
      } finally {
        await lock.close();
      }
    }
  }

  Future<RandomAccessFile> _acquireRefreshLock() async {
    final File file = File('${await _lockDir()}/kp_refresh.lock');
    final RandomAccessFile raf = await file.open(mode: FileMode.append);
    await raf.lock(FileLock.blockingExclusive);
    return raf;
  }
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._client);

  static const String _retriedKey = 'kp_auth_retried';

  final KpClient _client;
  Future<TokenPair?>? _refreshInFlight;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!options.headers.containsKey('Authorization')) {
      final TokenPair? pair = await _client._tokenStore.read();
      if (pair != null) {
        options.headers['Authorization'] = 'Bearer ${pair.accessToken}';
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final bool unauthorised = err.response?.statusCode == 401;
    final bool isAuthCall = err.requestOptions.path.startsWith('/v1/auth/');
    final bool alreadyRetried = err.requestOptions.extra[_retriedKey] == true;
    if (!unauthorised || isAuthCall || alreadyRetried) {
      handler.next(err);
      return;
    }
    final String? staleAccess =
        (err.requestOptions.headers['Authorization'] as String?)?.replaceFirst(
          'Bearer ',
          '',
        );
    // Concurrent 401s share one refresh instead of racing the rotation
    // (or, previously, skipping the retry outright).
    final TokenPair? refreshed = await (_refreshInFlight ??= _client
        ._refresh(staleAccessToken: staleAccess)
        .whenComplete(() => _refreshInFlight = null));
    if (refreshed == null) {
      handler.next(err);
      return;
    }
    final Options retryOptions = Options(
      method: err.requestOptions.method,
      headers: <String, dynamic>{
        ...err.requestOptions.headers,
        'Authorization': 'Bearer ${refreshed.accessToken}',
      },
      extra: <String, dynamic>{...err.requestOptions.extra, _retriedKey: true},
    );
    try {
      final Response<dynamic> retry = await _client._dio.request<dynamic>(
        err.requestOptions.path,
        data: err.requestOptions.data,
        queryParameters: err.requestOptions.queryParameters,
        options: retryOptions,
      );
      handler.resolve(retry);
    } on DioException catch (retryErr) {
      handler.next(retryErr);
    }
  }
}

final Provider<KpClient> kpClientProvider = Provider<KpClient>(
  (ref) => KpClient(ref.read(tokenStoreProvider)),
);
