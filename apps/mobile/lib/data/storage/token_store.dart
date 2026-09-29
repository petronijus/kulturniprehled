import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Thin wrapper around platform secure storage (Android Keystore-backed
// ciphers, iOS Keychain). Tokens never reach disk in plaintext on either
// platform.

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
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  static const String _accessKey = 'kp.access_token';
  static const String _refreshKey = 'kp.refresh_token';
  static const String _accessExpKey = 'kp.access_expires_at';
  static const String _refreshExpKey = 'kp.refresh_expires_at';

  final FlutterSecureStorage _storage;
  bool _upgradeChecked = false;

  Future<TokenPair?> read() async {
    if (!_upgradeChecked) {
      _upgradeChecked = true;
      await _reportUpgradeLoss();
    }
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

  // flutter_secure_storage 11 cannot read what v9 stored in Android's
  // EncryptedSharedPreferences; the first access discards it and the user
  // signs in again. Say so, so the sign-out has a reason in the log.
  Future<void> _reportUpgradeLoss() async {
    try {
      final SecureStorageUpgradeStatus status = await _storage
          .checkUpgradeStatus();
      if (status.hasDataLoss) {
        debugPrint(
          'kp-auth: secure storage lost ${status.entryCount} entries in the '
          'plugin upgrade (${status.reason.name}); signing in again',
        );
      }
    } catch (e, st) {
      debugPrint('kp-auth: secure storage upgrade check failed: $e\n$st');
    }
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
