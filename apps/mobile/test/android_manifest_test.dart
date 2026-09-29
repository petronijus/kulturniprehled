import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

// Tripwire for the silent "scheduled notifications never fire" bug.
//
// flutter_local_notifications does not merge its receivers from the library
// manifest; the app has to declare them. Without ScheduledNotificationReceiver
// every alarm fired into the void (the broadcast had no resolvable target),
// and without the boot receiver the alarms are gone after a reboot or an app
// update. Nothing at runtime reports either, so the manifest is pinned here.
const String _plugin = 'com.dexterous.flutterlocalnotifications';
const String _android = 'http://schemas.android.com/apk/res/android';

void main() {
  final XmlDocument manifest = XmlDocument.parse(
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
  );

  String? androidAttr(XmlElement element, String name) =>
      element.getAttribute(name, namespaceUri: _android);

  XmlElement? receiver(String name) {
    for (final XmlElement r in manifest.findAllElements('receiver')) {
      if (androidAttr(r, 'name') == name) return r;
    }
    return null;
  }

  test('declares the permissions scheduled reminders need', () {
    final Set<String?> permissions = manifest
        .findAllElements('uses-permission')
        .map((XmlElement p) => androidAttr(p, 'name'))
        .toSet();

    expect(
      permissions,
      containsAll(<String>[
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.SCHEDULE_EXACT_ALARM',
        'android.permission.USE_EXACT_ALARM',
        'android.permission.RECEIVE_BOOT_COMPLETED',
      ]),
    );
  });

  test(
    'declares the receiver that turns a fired alarm into a notification',
    () {
      final XmlElement? scheduled = receiver(
        '$_plugin.ScheduledNotificationReceiver',
      );

      expect(scheduled, isNotNull);
      expect(androidAttr(scheduled!, 'exported'), 'false');
    },
  );

  test(
    'declares the receiver that re-registers alarms after reboot and update',
    () {
      final XmlElement? boot = receiver(
        '$_plugin.ScheduledNotificationBootReceiver',
      );

      expect(boot, isNotNull);
      expect(androidAttr(boot!, 'exported'), 'false');
      final Set<String?> actions = boot
          .findAllElements('action')
          .map((XmlElement a) => androidAttr(a, 'name'))
          .toSet();
      expect(
        actions,
        containsAll(<String>[
          'android.intent.action.BOOT_COMPLETED',
          'android.intent.action.MY_PACKAGE_REPLACED',
        ]),
      );
    },
  );
}
