import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kp_mobile/core/widgets/parallax_layer.dart';

/// Tilt source that reports how many listeners it has.
class _Tilt extends ValueNotifier<Offset> {
  _Tilt() : super(Offset.zero);

  int listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }
}

const Key _layerKey = Key('layer');
const Key _childKey = Key('child');

Widget _harness({
  required ScrollController scroll,
  required _Tilt tilt,
  bool active = true,
  VoidCallback? onTap,
}) {
  return MaterialApp(
    home: TickerMode(
      enabled: active,
      child: ListView(
        controller: scroll,
        children: <Widget>[
          const SizedBox(height: 200),
          ParallaxLayer(
            key: _layerKey,
            scroll: scroll,
            tilt: tilt,
            scrollFactor: 0.5,
            tiltAmplitude: const Offset(10, 20),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: const SizedBox(key: _childKey, width: 100, height: 100),
            ),
          ),
          const SizedBox(height: 3000),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('shifts the child by tilt and by its distance from the '
      'viewport centre', (tester) async {
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    final _Tilt tilt = _Tilt();
    addTearDown(tilt.dispose);
    await tester.pumpWidget(_harness(scroll: scroll, tilt: tilt));

    final double viewportCentre =
        tester.view.physicalSize.height / tester.view.devicePixelRatio / 2;
    final double layerCentre = tester.getCenter(find.byKey(_layerKey)).dy;
    Offset shift() =>
        tester.getTopLeft(find.byKey(_childKey)) -
        tester.getTopLeft(find.byKey(_layerKey));

    expect(shift().dy, closeTo((viewportCentre - layerCentre) * 0.5, 0.01));

    tilt.value = const Offset(0.5, -1);
    await tester.pump();
    expect(shift().dx, closeTo(5, 0.01));
    expect(
      shift().dy,
      closeTo((viewportCentre - layerCentre) * 0.5 - 20, 0.01),
    );

    // Scrolling moves the layer up the viewport: the shift follows in the
    // same frame, with no rebuild in between.
    scroll.jumpTo(100);
    await tester.pump();
    final double scrolledCentre = tester.getCenter(find.byKey(_layerKey)).dy;
    expect(scrolledCentre, closeTo(layerCentre - 100, 0.01));
    expect(
      shift().dy,
      closeTo((viewportCentre - scrolledCentre) * 0.5 - 20, 0.01),
    );
  });

  testWidgets('hit testing follows the painted shift', (tester) async {
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    final _Tilt tilt = _Tilt();
    addTearDown(tilt.dispose);
    int taps = 0;
    await tester.pumpWidget(
      _harness(scroll: scroll, tilt: tilt, onTap: () => taps++),
    );

    await tester.tap(find.byKey(_childKey));

    expect(taps, 1);
  });

  testWidgets('a hidden branch stops repainting on tilt and catches up when '
      'shown', (tester) async {
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    final _Tilt tilt = _Tilt();
    addTearDown(tilt.dispose);
    await tester.pumpWidget(_harness(scroll: scroll, tilt: tilt));
    expect(tilt.listeners, 1);

    await tester.pumpWidget(
      _harness(scroll: scroll, tilt: tilt, active: false),
    );
    expect(tilt.listeners, 0);

    tilt.value = const Offset(1, 0);
    final RenderObject layer = tester.renderObject(find.byKey(_layerKey));
    expect(layer.debugNeedsPaint, isFalse);

    await tester.pumpWidget(_harness(scroll: scroll, tilt: tilt));
    expect(tilt.listeners, 1);
    expect(
      tester.getTopLeft(find.byKey(_childKey)).dx -
          tester.getTopLeft(find.byKey(_layerKey)).dx,
      closeTo(10, 0.01),
    );
  });
}
