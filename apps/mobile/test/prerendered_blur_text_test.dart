import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kp_mobile/core/widgets/prerendered_blur_text.dart';

const TextStyle _style = TextStyle(fontSize: 40, height: 1.0);

void main() {
  testWidgets('lays out like the one-line text it blurs', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                PrerenderedBlurText(
                  'Listopad',
                  key: Key('blur'),
                  style: _style,
                  sigma: 7.5,
                ),
                Text('Listopad', key: Key('plain'), style: _style, maxLines: 1),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const Key('blur'))),
      tester.getSize(find.byKey(const Key('plain'))),
    );
    // The blurred label and the reference text both announce it.
    expect(find.bySemanticsLabel('Listopad'), findsNWidgets(2));
  });

  testWidgets('re-renders when the text changes and survives unmount', (
    tester,
  ) async {
    Widget label(String text) => MaterialApp(
      home: Material(
        child: PrerenderedBlurText(text, style: _style, sigma: 7.5),
      ),
    );
    await tester.pumpWidget(label('Listopad'));
    await tester.pumpWidget(label('Prosinec'));
    expect(find.bySemanticsLabel('Prosinec'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    // Mounting the first label again reuses its cached bitmap through a
    // fresh clone; the unmounted widgets disposed only their own clones.
    await tester.pumpWidget(label('Listopad'));
    expect(tester.takeException(), isNull);
  });
}
