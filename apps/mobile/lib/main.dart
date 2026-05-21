import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:kp_mobile/core/config.dart';
import 'package:kp_mobile/core/routing/app_router.dart';
import 'package:kp_mobile/core/theme.dart';
import 'package:kp_mobile/features/notifications/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  // Transparent system bars so the white app background bleeds all the way
  // up — no Android scrim under the status-bar clock/icons.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await initializeDateFormatting('cs');

  const String dsn = AppConfig.sentryDsn;
  if (dsn.isEmpty) {
    // Dev builds: skip the SDK entirely so a stray exception in our code
    // doesn't try to phone home before we've configured anything.
    runApp(const ProviderScope(child: KpApp()));
    return;
  }

  await SentryFlutter.init((options) {
    options
      ..dsn = dsn
      ..environment = AppConfig.sentryEnvironment
      ..tracesSampleRate = 0;
  }, appRunner: () => runApp(const ProviderScope(child: KpApp())));
}

class KpApp extends ConsumerWidget {
  const KpApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Boot the notification scheduler so it (re)plans local notifications
    // every time the agenda cache changes. No-op until the first sync.
    ref.watch(notificationSchedulerProvider);
    return MaterialApp.router(
      title: 'Kulturní Přehled',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.light,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
