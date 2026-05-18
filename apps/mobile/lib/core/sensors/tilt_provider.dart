import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Single shared accelerometer subscription, exposed as a smoothed
/// [ValueListenable] of normalised tilt (each axis clamped to ±1).
///
/// Every screen that drives a parallax (agenda, calendar) reads this
/// listenable instead of opening its own [accelerometerEventStream] —
/// one stream, one smoother, one notifier, regardless of how many
/// branches are mounted. The subscription opens on first read and
/// stays alive as long as anyone is holding the provider (which, given
/// the IndexedStack keeps every branch alive, is the lifetime of the
/// app).
final Provider<ValueListenable<Offset>> tiltListenableProvider =
    Provider<ValueListenable<Offset>>((Ref ref) {
      final ValueNotifier<Offset> notifier = ValueNotifier<Offset>(Offset.zero);
      final StreamSubscription<AccelerometerEvent> sub =
          accelerometerEventStream(
            samplingPeriod: SensorInterval.uiInterval,
          ).listen((AccelerometerEvent event) {
            // Normalise: x is left/right tilt, (y - 9.81) is forward/back
            // from phone-held-vertical reference. Clamp to ±1.
            final Offset raw = Offset(
              (event.x / 3.0).clamp(-1.0, 1.0),
              ((event.y - 9.81) / 3.0).clamp(-1.0, 1.0),
            );
            const double alpha = 0.15;
            notifier.value = notifier.value * (1 - alpha) + raw * alpha;
          });
      ref.onDispose(() {
        sub.cancel();
        notifier.dispose();
      });
      return notifier;
    });
