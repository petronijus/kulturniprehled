import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import 'package:kp_mobile/features/sync/offline_cache_service.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';

/// Headless WorkManager callback. Runs in a fresh isolate every time the
/// scheduler fires our periodic task — no providers, no Flutter widgets,
/// not even the main isolate's `ProviderContainer`. We stand up our own
/// ProviderContainer here, pull the sync delta, prime the offline cache,
/// and tear everything down before returning.
@pragma('vm:entry-point')
void kpBackgroundCallback() {
  Workmanager().executeTask((
    String task,
    Map<String, dynamic>? inputData,
  ) async {
    if (task != BackgroundSync.periodicTaskName) {
      return true;
    }
    WidgetsFlutterBinding.ensureInitialized();
    final ProviderContainer container = ProviderContainer();
    try {
      await container.read(syncControllerProvider.notifier).pullChanges();
      // `pullChanges` fires the cache refresh unawaited so the foreground
      // sync spinner doesn't gate on slow downloads. In the background
      // we want the downloads themselves — await one more refresh pass.
      // The second call is a near-no-op when the first already finished
      // (every download checks the DB before hitting the network).
      await container.read(offlineCacheServiceProvider).refresh();
    } catch (e, st) {
      // Don't ask WorkManager to retry (no `return false`) — the next
      // periodic firing tries again anyway. But DO surface the error to
      // logcat; this was previously swallowed silently, which is exactly
      // what hid the background "new event" notification failure.
      debugPrint('kp-bg-sync failed: $e\n$st');
    } finally {
      container.dispose();
    }
    return true;
  });
}

class BackgroundSync {
  // The task name doubles as the unique identifier — registering it
  // again is idempotent (overwrites the existing schedule).
  static const String periodicTaskName = 'kp-bg-sync';

  /// Wires up the WorkManager plugin and (re-)registers the periodic
  /// sync. Call once from `main()` after `WidgetsFlutterBinding`.
  static Future<void> initializeAndSchedule() async {
    await Workmanager().initialize(kpBackgroundCallback);
    await Workmanager().registerPeriodicTask(
      periodicTaskName,
      periodicTaskName,
      frequency: const Duration(minutes: 30),
      // Wait 5 min after install before the first fire so a fresh user
      // isn't fighting their cold-start sync.
      initialDelay: const Duration(minutes: 5),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }
}
