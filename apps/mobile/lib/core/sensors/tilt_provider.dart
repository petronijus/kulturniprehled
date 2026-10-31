import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Turns raw accelerometer samples (m/s²) into a smoothed, normalised tilt
/// (each axis clamped to ±1) and publishes it only when it has moved by at
/// least [deadZone].
///
/// The dead zone is what lets a screen go idle: an accelerometer never reads
/// the same value twice, so without it every listener — each parallax layer
/// on the agenda and the calendar — repaints on every sample (~60 Hz) even
/// while the phone lies still. The largest consumer drifts 6 px at full
/// tilt, so the default 0.02 is a 0.12 px step: below what anyone sees,
/// above sensor noise and hand tremor after smoothing.
class TiltSmoother extends ChangeNotifier implements ValueListenable<Offset> {
  TiltSmoother({this.alpha = 0.15, this.deadZone = 0.02});

  /// Weight of each new sample in the exponential moving average.
  final double alpha;

  /// Minimum distance from the last published value before listeners hear
  /// about a change.
  final double deadZone;

  Offset _smoothed = Offset.zero;
  Offset _published = Offset.zero;

  @override
  Offset get value => _published;

  /// [x] is left/right tilt; [y] is measured against the phone held
  /// upright, where gravity reads 9.81 on that axis.
  void addSample(double x, double y) {
    final Offset raw = Offset(
      (x / 3.0).clamp(-1.0, 1.0),
      ((y - 9.81) / 3.0).clamp(-1.0, 1.0),
    );
    _smoothed = _smoothed * (1 - alpha) + raw * alpha;
    if ((_smoothed - _published).distance >= deadZone) {
      _published = _smoothed;
      notifyListeners();
    }
  }
}

/// Single shared accelerometer subscription, exposed as a smoothed
/// [ValueListenable] of normalised tilt.
///
/// Every screen that drives a parallax (agenda, calendar) reads this
/// listenable instead of opening its own [accelerometerEventStream] —
/// one stream, one smoother, regardless of how many branches are mounted.
/// The subscription opens on first read and stays alive as long as anyone
/// holds the provider (with the IndexedStack keeping every branch alive,
/// that is the lifetime of the app); listeners on hidden branches detach
/// themselves through [TickerMode].
final Provider<ValueListenable<Offset>>
tiltListenableProvider = Provider<ValueListenable<Offset>>((Ref ref) {
  final TiltSmoother smoother = TiltSmoother();
  final StreamSubscription<AccelerometerEvent> sub = accelerometerEventStream(
    samplingPeriod: SensorInterval.uiInterval,
  ).listen((AccelerometerEvent event) => smoother.addSample(event.x, event.y));
  ref.onDispose(() {
    sub.cancel();
    smoother.dispose();
  });
  return smoother;
});
