import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A single line of [text] in [style], Gaussian-blurred by [sigma] — drawn
/// as a bitmap rendered once instead of an `ImageFiltered` blur.
///
/// A live blur filter re-runs on the GPU every frame the text is painted;
/// on a parallax layer that is every frame of a scroll. Here the blur runs
/// once per (text, style, sigma, device pixel ratio) and is kept in a small
/// LRU cache shared by every instance, so scrolling past the same month
/// label again costs one bitmap draw.
///
/// Layout matches a plain one-line [Text]: the widget sizes to the
/// unblurred text, and the blur halo spills outside it exactly as an
/// `ImageFiltered` halo would.
class PrerenderedBlurText extends StatefulWidget {
  const PrerenderedBlurText(
    this.text, {
    super.key,
    required this.style,
    required this.sigma,
  });

  final String text;
  final TextStyle style;
  final double sigma;

  @override
  State<PrerenderedBlurText> createState() => _PrerenderedBlurTextState();
}

class _PrerenderedBlurTextState extends State<PrerenderedBlurText> {
  _BlurredText? _entry;
  _CacheKey? _key;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant PrerenderedBlurText oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final _CacheKey key = _CacheKey(
      text: widget.text,
      style: widget.style,
      sigma: widget.sigma,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    if (key == _key) {
      return;
    }
    _entry?.dispose();
    _entry = _BlurCache.instance.take(key);
    _key = key;
  }

  @override
  void dispose() {
    _entry?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _BlurredText entry = _entry!;
    return Semantics(
      label: widget.text,
      child: CustomPaint(size: entry.layoutSize, painter: _BlurPainter(entry)),
    );
  }
}

class _BlurPainter extends CustomPainter {
  _BlurPainter(this.entry);

  final _BlurredText entry;

  @override
  void paint(Canvas canvas, Size size) {
    final double dpr = entry.devicePixelRatio;
    final ui.Image image = entry.image;
    canvas.drawImageRect(
      image,
      Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(
        -entry.halo,
        -entry.halo,
        image.width / dpr,
        image.height / dpr,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_BlurPainter oldDelegate) =>
      !identical(oldDelegate.entry.image, entry.image) &&
      !oldDelegate.entry.image.isCloneOf(entry.image);
}

@immutable
class _CacheKey {
  const _CacheKey({
    required this.text,
    required this.style,
    required this.sigma,
    required this.devicePixelRatio,
    required this.textScaler,
  });

  final String text;
  final TextStyle style;
  final double sigma;
  final double devicePixelRatio;
  final TextScaler textScaler;

  @override
  bool operator ==(Object other) =>
      other is _CacheKey &&
      other.text == text &&
      other.style == style &&
      other.sigma == sigma &&
      other.devicePixelRatio == devicePixelRatio &&
      other.textScaler == textScaler;

  @override
  int get hashCode =>
      Object.hash(text, style, sigma, devicePixelRatio, textScaler);
}

/// One holder's handle on a cached bitmap. Each widget owns a clone of the
/// cached image, so evicting the cache's own handle never disposes an image
/// a widget is still painting.
class _BlurredText {
  _BlurredText({
    required this.image,
    required this.layoutSize,
    required this.halo,
    required this.devicePixelRatio,
  });

  final ui.Image image;

  /// Size of the unblurred text — what the widget lays out to.
  final Size layoutSize;

  /// Logical pixels of blur halo around the text on every side.
  final double halo;
  final double devicePixelRatio;

  _BlurredText clone() => _BlurredText(
    image: image.clone(),
    layoutSize: layoutSize,
    halo: halo,
    devicePixelRatio: devicePixelRatio,
  );

  void dispose() => image.dispose();
}

class _BlurCache {
  _BlurCache._();

  static final _BlurCache instance = _BlurCache._();

  /// A handful of month labels are on screen at once; a season spans about
  /// twelve. Six keeps the neighbours of the visible months warm.
  static const int _capacity = 6;

  final LinkedHashMap<_CacheKey, _BlurredText> _entries =
      LinkedHashMap<_CacheKey, _BlurredText>();

  _BlurredText take(_CacheKey key) {
    _BlurredText? entry = _entries.remove(key);
    entry ??= _render(key);
    _entries[key] = entry;
    while (_entries.length > _capacity) {
      final _CacheKey oldest = _entries.keys.first;
      _entries.remove(oldest)!.dispose();
    }
    return entry.clone();
  }

  static _BlurredText _render(_CacheKey key) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: key.text, style: key.style),
      textDirection: TextDirection.ltr,
      textScaler: key.textScaler,
      maxLines: 1,
    )..layout();
    // Three sigma holds all but a sliver of a Gaussian's weight.
    final double halo = key.sigma * 3;
    final double dpr = key.devicePixelRatio;
    final Size layoutSize = painter.size;

    // Rendered through the same layer path an on-screen `ImageFiltered`
    // takes (an ImageFilterLayer under the device-pixel-ratio transform that
    // `toImageSync` adds), so the blur looks exactly as the live filter did.
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), Offset(halo, halo));
    painter.dispose();
    final Rect bounds = Rect.fromLTWH(
      0,
      0,
      layoutSize.width + halo * 2,
      layoutSize.height + halo * 2,
    );
    final OffsetLayer root = OffsetLayer();
    final ImageFilterLayer blur = ImageFilterLayer(
      imageFilter: ui.ImageFilter.blur(sigmaX: key.sigma, sigmaY: key.sigma),
    );
    final PictureLayer text = PictureLayer(bounds)
      ..picture = recorder.endRecording();
    blur.append(text);
    root.append(blur);
    final ui.Image image = root.toImageSync(bounds, pixelRatio: dpr);
    root.dispose();
    return _BlurredText(
      image: image,
      layoutSize: layoutSize,
      halo: halo,
      devicePixelRatio: dpr,
    );
  }
}
