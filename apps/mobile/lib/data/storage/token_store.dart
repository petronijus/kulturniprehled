import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Thin wrapper around platform secure storage (Android Keystore-backed
// EncryptedSharedPreferences, iOS Keychain). Tokens never reach disk in
// plaintext on either platform.

class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
}

class TokenStore {
  TokenStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  static const String _accessKey = 'kp.access_token';
  static const String _refreshKey = 'kp.refresh_token';
  static const String _accessExpKey = 'kp.access_expires_at';
  static const String _refreshExpKey = 'kp.refresh_expires_at';

  final FlutterSecureStorage _storage;

  Future<TokenPair?> read() async {
    final Map<String, String> all = await _storage.readAll();
    final String? access = all[_accessKey];
    final String? refresh = all[_refreshKey];
    final String? accessExp = all[_accessExpKey];
    final String? refreshExp = all[_refreshExpKey];
    if (access == null ||
        refresh == null ||
        accessExp == null ||
        refreshExp == null) {
      return null;
    }
    return TokenPair(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: DateTime.parse(accessExp),
      refreshExpiresAt: DateTime.parse(refreshExp),
    );
  }

  Future<void> write(TokenPair pair) async {
    await _storage.write(key: _accessKey, value: pair.accessToken);
    await _storage.write(key: _refreshKey, value: pair.refreshToken);
    await _storage.write(
      key: _accessExpKey,
      value: pair.accessExpiresAt.toIso8601String(),
    );
    await _storage.write(
      key: _refreshExpKey,
      value: pair.refreshExpiresAt.toIso8601String(),
    );
  }

  Future<void> clear() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _accessExpKey);
    await _storage.delete(key: _refreshExpKey);
  }
}

final Provider<TokenStore> tokenStoreProvider = Provider<TokenStore>(
  (ref) => TokenStore(),
);
