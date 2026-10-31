import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kp_mobile/core/widgets/blur_in_text.dart';

const TextStyle _style = TextStyle(
  fontFamily: 'Gloock',
  fontSize: 50,
  height: 1.0,
  color: Colors.black,
);

const String _title = 'Symfonie';
const Key _animated = Key('animated');
const Key _plain = Key('plain');

Future<Uint8List> _pixels(WidgetTester tester, Key key) async {
  final RenderRepaintBoundary boundary =
      tester.renderObject(find.byKey(key)) as RenderRepaintBoundary;
  final ui.Image image = (await tester.runAsync(boundary.toImage))!;
  final ByteData bytes = (await tester.runAsync<ByteData?>(image.toByteData))!;
  image.dispose();
  return bytes.buffer.asUint8List();
}

Widget _frame(Key key, Widget child) => RepaintBoundary(
  key: key,
  child: Container(color: Colors.white, width: 300, height: 60, child: child),
);

Future<void> _pumpPair(WidgetTester tester) async {
  final FontLoader loader = FontLoader('Gloock')
    ..addFont(rootBundle.load('assets/fonts/Gloock-Regular.ttf'));
  await loader.load();
  await tester.pumpWidget(
    MaterialApp(
      home: Material(
        child: Column(
          children: <Widget>[
            _frame(_animated, const BlurInText(text: _title, style: _style)),
            _frame(
              _plain,
              Text(_title, style: _style.copyWith(inherit: false)),
            ),
          ],
        ),
      ),
    ),
  );
}

int _ink(Uint8List rgba) {
  int ink = 0;
  for (int i = 0; i < rgba.length; i += 4) {
    if (rgba[i] < 250) ink++;
  }
  return ink;
}

void main() {
  testWidgets('starts invisible and lands exactly on the plain text', (
    tester,
  ) async {
    await _pumpPair(tester);

    expect(_ink(await _pixels(tester, _animated)), 0);

    await tester.pumpAndSettle();
    expect(
      await _pixels(tester, _animated),
      orderedEquals(await _pixels(tester, _plain)),
    );
  });
}
