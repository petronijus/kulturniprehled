import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Animates a text block in letter-by-letter — each glyph starts blurred and
/// transparent, then resolves into the final letter. The whole run staggers
/// from left to right.
///
/// Rendering strategy: always paint the master TextPainter as the base layer
/// (so kerning, ligatures, line metrics are pixel-identical to a plain
/// [Text]). For each char still animating, clear that char's box from the
/// composited layer and redraw it inside a blurred saveLayer. Done chars
/// are left as the master painted them — no per-char paint path, no
/// baseline shift at the end of the animation.
class BlurInText extends StatefulWidget {
  const BlurInText({
    super.key,
    required this.text,
    required this.style,
    this.duration = const Duration(milliseconds: 600),
    this.perCharStagger = const Duration(milliseconds: 35),
    this.startBlur = 16.0,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.restartTrigger,
    this.startDelay = Duration.zero,
  });

  final String text;
  final TextStyle style;
  final Duration duration;
  final Duration perCharStagger;
  final double startBlur;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  /// Optional listener — every time it notifies, the controller resets
  /// and the blur-in animation plays again. Lets callers replay the
  /// animation when a screen comes back into view, without having to
  /// rebuild this widget.
  final Listenable? restartTrigger;

  /// Delay before the animation starts playing on first mount / on each
  /// replay. Useful for staggering a list of titles so they cascade
  /// in instead of all blurring in together.
  final Duration startDelay;

  @override
  State<BlurInText> createState() => _BlurInTextState();
}

class _BlurInTextState extends State<BlurInText>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late int _totalMs;

  /// Shaped text and per-glyph geometry, shared by every paint. Shaping in
  /// `paint()` re-laid the title — and one painter per animating glyph —
  /// on every frame, which on a parallax list is every frame of a scroll.
  _TitleLayout? _layout;

  _TitleLayout get _titleLayout => _layout ??= _TitleLayout(
    text: widget.text,
    style: widget.style,
    maxLines: widget.maxLines,
    textAlign: widget.textAlign ?? TextAlign.start,
  );

  @override
  void initState() {
    super.initState();
    _initController();
    widget.restartTrigger?.addListener(_replay);
  }

  void _initController() {
    _totalMs =
        widget.duration.inMilliseconds +
        widget.text.length * widget.perCharStagger.inMilliseconds;
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _totalMs),
    );
    _startWithDelay();
  }

  void _startWithDelay() {
    if (widget.startDelay == Duration.zero) {
      _ctrl.forward();
      return;
    }
    Future<void>.delayed(widget.startDelay, () {
      if (mounted) _ctrl.forward();
    });
  }

  void _replay() {
    if (!mounted) return;
    _ctrl
      ..stop()
      ..reset();
    _startWithDelay();
  }

  @override
  void didUpdateWidget(covariant BlurInText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.restartTrigger != widget.restartTrigger) {
      oldWidget.restartTrigger?.removeListener(_replay);
      widget.restartTrigger?.addListener(_replay);
    }
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.maxLines != widget.maxLines ||
        oldWidget.textAlign != widget.textAlign) {
      _layout?.dispose();
      _layout = null;
    }
    if (oldWidget.text != widget.text) {
      _ctrl.dispose();
      _initController();
    }
  }

  @override
  void dispose() {
    widget.restartTrigger?.removeListener(_replay);
    _ctrl.dispose();
    _layout?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Transparent text owns the layout so `find.text` and screen readers
    // still see the title, and the CustomPaint sits on top in the exact
    // same area / size.
    final TextStyle invisible = widget.style.copyWith(
      color: const Color(0x00000000),
    );
    return Stack(
      alignment: Alignment.topLeft,
      children: <Widget>[
        Text(
          widget.text,
          style: invisible,
          maxLines: widget.maxLines,
          overflow: widget.overflow ?? TextOverflow.clip,
          textAlign: widget.textAlign,
        ),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) => AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) => CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: _BlurInPainter(
                  layout: _titleLayout,
                  startBlur: widget.startBlur,
                  perCharStaggerMs: widget.perCharStagger.inMilliseconds
                      .toDouble(),
                  charDurationMs: widget.duration.inMilliseconds.toDouble(),
                  totalMs: _totalMs.toDouble(),
                  animationT: _ctrl.value,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One grapheme of the title: where the master painted it and a painter
/// that redraws it alone.
class _Glyph {
  _Glyph({required this.start, required this.rects, required this.painter});

  /// UTF-16 offset of the grapheme; drives its place in the stagger.
  final int start;

  /// The grapheme's boxes with line height (`BoxHeightStyle.max`), so erasing
  /// one removes the whole line slice of the master's drawing.
  final List<Rect> rects;

  /// The grapheme alone, in the full style colour; opacity is applied by the
  /// layer it is drawn into.
  final TextPainter painter;
}

/// The shaped title and its glyphs for one layout width. Built on the first
/// paint at a width and reused by every frame after it.
class _TitleLayout {
  _TitleLayout({
    required String text,
    required this.style,
    required int? maxLines,
    required TextAlign textAlign,
  }) : master = TextPainter(
         text: TextSpan(text: text, style: style),
         textDirection: TextDirection.ltr,
         maxLines: maxLines,
         textAlign: textAlign,
       );

  final TextStyle style;
  final TextPainter master;
  double? _width;
  List<_Glyph> _glyphs = const <_Glyph>[];

  List<_Glyph> glyphsFor(double width) {
    master.layout(maxWidth: width);
    if (_width == width) {
      return _glyphs;
    }
    _disposeGlyphs();
    _width = width;
    final String text = master.plainText;
    final List<_Glyph> glyphs = <_Glyph>[];
    int start = 0;
    for (final String grapheme in text.characters) {
      final int end = start + grapheme.length;
      final List<Rect> rects = master
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: end),
            boxHeightStyle: ui.BoxHeightStyle.max,
          )
          .map((ui.TextBox box) => box.toRect())
          .toList(growable: false);
      if (rects.isNotEmpty) {
        glyphs.add(
          _Glyph(
            start: start,
            rects: rects,
            painter: TextPainter(
              text: TextSpan(text: grapheme, style: style),
              textDirection: TextDirection.ltr,
            )..layout(),
          ),
        );
      }
      start = end;
    }
    _glyphs = glyphs;
    return glyphs;
  }

  void _disposeGlyphs() {
    for (final _Glyph glyph in _glyphs) {
      glyph.painter.dispose();
    }
    _glyphs = const <_Glyph>[];
  }

  void dispose() {
    _disposeGlyphs();
    master.dispose();
  }
}

class _BlurInPainter extends CustomPainter {
  _BlurInPainter({
    required this.layout,
    required this.startBlur,
    required this.perCharStaggerMs,
    required this.charDurationMs,
    required this.totalMs,
    required this.animationT,
  });

  final _TitleLayout layout;
  final double startBlur;
  final double perCharStaggerMs;
  final double charDurationMs;
  final double totalMs;
  final double animationT;

  @override
  void paint(Canvas canvas, Size size) {
    final List<_Glyph> glyphs = layout.glyphsFor(size.width);
    final TextPainter master = layout.master;

    if (animationT >= 1.0) {
      // Fast path once everything has finished animating in.
      master.paint(canvas, Offset.zero);
      return;
    }
    if (animationT <= 0) {
      // Nothing has started: the title is fully transparent. Erasing glyph
      // boxes from the master would leave the parts of letters that
      // overhang their box (the hook of "f") faintly visible.
      return;
    }

    // Composite everything into one offscreen layer so the clear / dstOut
    // passes below act on the master's drawing only (they would punch
    // through to the screen otherwise).
    canvas.saveLayer(Offset.zero & size, Paint());
    master.paint(canvas, Offset.zero);

    final Paint erase = Paint()..blendMode = BlendMode.clear;
    for (final _Glyph glyph in glyphs) {
      final double startFrac = (glyph.start * perCharStaggerMs) / totalMs;
      final double endFrac = startFrac + (charDurationMs / totalMs);
      // Already-finished chars stay as the master painted them — no
      // baseline shift possible because we don't re-render them.
      if (animationT >= endFrac) continue;

      if (animationT <= startFrac) {
        // Not started: fully transparent. Erasing is the whole job; drawing
        // the glyph at zero opacity through a blur layer would cost a layer
        // for nothing.
        for (final Rect rect in glyph.rects) {
          canvas.drawRect(rect, erase);
        }
        continue;
      }

      final double t = (animationT - startFrac) / (endFrac - startFrac);
      final double opacity = Curves.easeOutCubic.transform(t);
      final double blur = startBlur * (1 - opacity);

      if (blur > 0.5) {
        for (final Rect rect in glyph.rects) {
          // Erase the master's drawing of this char, then redraw it blurred
          // and faded. Blur is linear, so fading the layer equals fading
          // the glyph before blurring it. The glyph's painter has the
          // master's font, style and line height, painted at the
          // master-measured line top, so its baseline matches the master's.
          canvas
            ..drawRect(rect, erase)
            ..saveLayer(
              rect.inflate(blur * 4),
              Paint()
                ..color = Color.fromRGBO(0, 0, 0, opacity)
                ..imageFilter = ui.ImageFilter.blur(
                  sigmaX: blur,
                  sigmaY: blur,
                  tileMode: TileMode.decal,
                ),
            );
          glyph.painter.paint(canvas, rect.topLeft);
          canvas.restore();
        }
      } else {
        // Sharp enough to be the master's own glyph: just fade it in place.
        // dstOut keeps `dst × (1 − srcAlpha)`, i.e. the master's pixels at
        // `opacity`, with no layer and no redraw.
        final Paint fade = Paint()
          ..blendMode = BlendMode.dstOut
          ..color = Color.fromRGBO(0, 0, 0, 1 - opacity);
        for (final Rect rect in glyph.rects) {
          canvas.drawRect(rect, fade);
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BlurInPainter oldDelegate) =>
      !identical(oldDelegate.layout, layout) ||
      oldDelegate.animationT != animationT;
}
