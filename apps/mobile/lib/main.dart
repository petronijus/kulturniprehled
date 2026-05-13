import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:kp_mobile/core/config.dart';
import 'package:kp_mobile/core/routing/app_router.dart';
import 'package:kp_mobile/core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
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
    return MaterialApp.router(
      title: 'Kulturní Přehled',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
