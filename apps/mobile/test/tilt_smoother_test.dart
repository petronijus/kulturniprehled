import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:kp_mobile/core/sensors/tilt_provider.dart';

void main() {
  test('sensor noise on a still phone never notifies', () {
    final TiltSmoother tilt = TiltSmoother();
    addTearDown(tilt.dispose);
    int notifications = 0;
    tilt.addListener(() => notifications++);
    final math.Random random = math.Random(1);

    // Ten seconds at the UI sampling rate: a phone lying upright, the
    // accelerometer jittering by ±0.05 m/s² on both axes.
    for (int i = 0; i < 600; i++) {
      tilt.addSample(
        0.1 * (random.nextDouble() - 0.5),
        9.81 + 0.1 * (random.nextDouble() - 0.5),
      );
    }

    expect(notifications, 0);
    expect(tilt.value, Offset.zero);
  });

  test('a real tilt is published and converges', () {
    final TiltSmoother tilt = TiltSmoother();
    addTearDown(tilt.dispose);
    int notifications = 0;
    tilt.addListener(() => notifications++);

    // Phone rolled right: x reads 1.5 m/s², half of full-scale tilt.
    for (int i = 0; i < 120; i++) {
      tilt.addSample(1.5, 9.81);
    }

    expect(notifications, greaterThan(5));
    expect(tilt.value.dx, closeTo(0.5, 0.02));
    expect(tilt.value.dy, 0);
  });

  test('a steady phone stops notifying once the average settles', () {
    final TiltSmoother tilt = TiltSmoother();
    addTearDown(tilt.dispose);
    for (int i = 0; i < 120; i++) {
      tilt.addSample(1.5, 9.81);
    }
    int notifications = 0;
    tilt.addListener(() => notifications++);

    for (int i = 0; i < 600; i++) {
      tilt.addSample(1.5, 9.81);
    }

    expect(notifications, 0);
  });

  test('each axis is clamped to full scale', () {
    final TiltSmoother tilt = TiltSmoother(alpha: 1);
    addTearDown(tilt.dispose);

    tilt.addSample(30, -20);

    expect(tilt.value, const Offset(1, -1));
  });
}
