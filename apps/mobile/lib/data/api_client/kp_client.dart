import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kp_mobile/core/config.dart';
import 'package:kp_mobile/data/storage/token_store.dart';

// Dio-based KP API client.
//
// The auth interceptor injects the bearer token on every request, and
// transparently refreshes the access token on the first 401 with a fresh
// refresh-token rotation. If the refresh itself fails the client clears the
// token store so the router redirects to /login on the next frame.

class TokenRefreshFailure implements Exception {
  const TokenRefreshFailure();
  @override
  String toString() => 'token refresh failed';
}

class KpClient {
  KpClient(this._tokenStore, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: AppConfig.apiBaseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              headers: <String, String>{'Accept': 'application/json'},
            ),
          ) {
    _dio.interceptors.add(_AuthInterceptor(this));
  }

  final Dio _dio;
  final TokenStore _tokenStore;

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

  Future<TokenPair?> _refresh() async {
    final TokenPair? current = await _tokenStore.read();
    if (current == null) {
      return null;
    }
    try {
      final Response<dynamic> response =
          await Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl)).post<dynamic>(
            '/v1/auth/refresh',
            data: <String, String>{'refresh_token': current.refreshToken},
          );
      final Map<String, dynamic> body = response.data! as Map<String, dynamic>;
      final TokenPair pair = TokenPair(
        accessToken: body['access_token'] as String,
        refreshToken: body['refresh_token'] as String,
        accessExpiresAt: DateTime.parse(body['access_expires_at'] as String),
        refreshExpiresAt: DateTime.parse(body['refresh_expires_at'] as String),
      );
      await _tokenStore.write(pair);
      return pair;
    } on DioException {
      await _tokenStore.clear();
      return null;
    }
  }
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._client);

  final KpClient _client;
  bool _isRetrying = false;

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
    if (!unauthorised || isAuthCall || _isRetrying) {
      handler.next(err);
      return;
    }
    _isRetrying = true;
    try {
      final TokenPair? refreshed = await _client._refresh();
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
      );
      final Response<dynamic> retry = await _client._dio.request<dynamic>(
        err.requestOptions.path,
        data: err.requestOptions.data,
        queryParameters: err.requestOptions.queryParameters,
        options: retryOptions,
      );
      handler.resolve(retry);
    } finally {
      _isRetrying = false;
    }
  }
}

final Provider<KpClient> kpClientProvider = Provider<KpClient>(
  (ref) => KpClient(ref.read(tokenStoreProvider)),
);
