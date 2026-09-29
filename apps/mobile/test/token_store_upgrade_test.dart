import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kp_mobile/data/storage/token_store.dart';

// flutter_secure_storage 11 cannot decrypt what v9 kept in Android's
// EncryptedSharedPreferences; its first access discards the tokens. The
// user is signed out either way — the store must say why in the log
// instead of logging them out silently, and must still just read "none".
class _UpgradedStorage implements FlutterSecureStorage {
  _UpgradedStorage(this.status);

  final SecureStorageUpgradeStatus status;
  int upgradeChecks = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #checkUpgradeStatus) {
      upgradeChecks += 1;
      return Future<SecureStorageUpgradeStatus>.value(status);
    }
    if (invocation.memberName == #readAll) {
      // What the plugin returns once it has discarded the unreadable data.
      return Future<Map<String, String>>.value(<String, String>{});
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  late List<String> log;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    log = <String>[];
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => log.add(message ?? '');
  });

  tearDown(() => debugPrint = originalDebugPrint);

  test(
    'tokens lost in the plugin upgrade are logged, not dropped silently',
    () async {
      final TokenStore store = TokenStore(
        _UpgradedStorage(
          const SecureStorageUpgradeStatus(
            state: SecureStorageUpgradeState.legacyDataUnreadable,
            reason: SecureStorageUpgradeReason.legacyBackendPresent,
            entryCount: 4,
            willDiscardOnNextAccess: true,
          ),
        ),
      );

      expect(await store.read(), isNull);
      expect(
        log,
        contains(
          'kp-auth: secure storage lost 4 entries in the plugin upgrade '
          '(legacyBackendPresent); signing in again',
        ),
      );
    },
  );

  test('an intact store logs nothing and checks only once', () async {
    final _UpgradedStorage storage = _UpgradedStorage(
      const SecureStorageUpgradeStatus(state: SecureStorageUpgradeState.ok),
    );
    final TokenStore store = TokenStore(storage);

    await store.read();
    await store.read();

    expect(log, isEmpty);
    expect(storage.upgradeChecks, 1);
  });
}
