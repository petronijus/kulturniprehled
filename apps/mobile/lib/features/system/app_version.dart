import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The installed build as the stores list it, `1.3.2 (25)`: version name and
/// build number, so a glance tells whether a Play or TestFlight update landed.
final FutureProvider<String> appVersionProvider = FutureProvider<String>((
  ref,
) async {
  final PackageInfo info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
});
