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
    if (oldWidget.text != widget.text) {
      _ctrl.dispose();
      _initController();
    }
  }

  @override
  void dispose() {
    widget.restartTrigger?.removeListener(_replay);
    _ctrl.dispose();
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
                  text: widget.text,
                  style: widget.style,
                  startBlur: widget.startBlur,
                  perCharStaggerMs: widget.perCharStagger.inMilliseconds
                      .toDouble(),
                  charDurationMs: widget.duration.inMilliseconds.toDouble(),
                  totalMs: _totalMs.toDouble(),
                  animationT: _ctrl.value,
                  maxLines: widget.maxLines,
                  textAlign: widget.textAlign ?? TextAlign.start,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BlurInPainter extends CustomPainter {
  _BlurInPainter({
    required this.text,
    required this.style,
    required this.startBlur,
    required this.perCharStaggerMs,
    required this.charDurationMs,
    required this.totalMs,
    required this.animationT,
    required this.maxLines,
    required this.textAlign,
  });

  final String text;
  final TextStyle style;
  final double startBlur;
  final double perCharStaggerMs;
  final double charDurationMs;
  final double totalMs;
  final double animationT;
  final int? maxLines;
  final TextAlign textAlign;

  @override
  void paint(Canvas canvas, Size size) {
    final TextPainter master = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      textAlign: textAlign,
    )..layout(maxWidth: size.width);

    if (animationT >= 1.0) {
      // Fast path once everything has finished animating in.
      master.paint(canvas, Offset.zero);
      return;
    }

    // Composite everything into one offscreen layer so BlendMode.clear can
    // erase parts of the master after we draw it (clear has no effect when
    // drawing straight to the screen layer).
    final Rect bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint());
    master.paint(canvas, Offset.zero);

    int unitOffset = 0;
    int i = 0;
    while (i < text.length) {
      final String slice = text.substring(i).characters.first.toString();
      final int sliceLen = slice.length;
      final int start = unitOffset;
      final int end = unitOffset + sliceLen;
      unitOffset = end;
      i += sliceLen;

      final double startFrac = (start * perCharStaggerMs) / totalMs;
      final double endFrac = startFrac + (charDurationMs / totalMs);
      final double t;
      if (animationT <= startFrac) {
        t = 0;
      } else if (animationT >= endFrac) {
        t = 1;
      } else {
        t = (animationT - startFrac) / (endFrac - startFrac);
      }
      // Already-finished chars stay as the master painted them — no
      // baseline shift possible because we don't re-render them.
      if (t >= 1.0) continue;

      final double eased = Curves.easeOutCubic.transform(t.clamp(0.0, 1.0));
      final double opacity = eased;
      final double blur = startBlur * (1 - eased);

      // Use BoxHeightStyle.max so the box covers the line bounds, not just
      // the glyph extents — that way our redraw can erase + redraw the
      // whole line slice for this char without leaving stale pixels above
      // or below the glyph.
      final List<ui.TextBox> boxes = master.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
        boxHeightStyle: ui.BoxHeightStyle.max,
      );
      if (boxes.isEmpty) continue;

      for (final ui.TextBox box in boxes) {
        final Rect rect = box.toRect();
        // Erase the master's drawing of this char from the layer.
        canvas.drawRect(rect, Paint()..blendMode = BlendMode.clear);
        // Redraw the same char with current blur + opacity. The glyph's
        // own TextPainter has the same font/style/line height as master,
        // and we paint at the master-measured line top — baseline aligns
        // exactly with what master drew for the surrounding chars.
        final TextStyle charStyle = style.copyWith(
          color: (style.color ?? const Color(0xFF000000)).withValues(
            alpha: opacity,
          ),
        );
        final TextPainter glyph = TextPainter(
          text: TextSpan(text: slice, style: charStyle),
          textDirection: TextDirection.ltr,
        )..layout();

        if (blur > 0.5) {
          final Rect layerRect = rect.inflate(blur * 4);
          canvas.saveLayer(
            layerRect,
            Paint()
              ..imageFilter = ui.ImageFilter.blur(
                sigmaX: blur,
                sigmaY: blur,
                tileMode: TileMode.decal,
              ),
          );
          glyph.paint(canvas, Offset(rect.left, rect.top));
          canvas.restore();
        } else {
          glyph.paint(canvas, Offset(rect.left, rect.top));
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BlurInPainter oldDelegate) =>
      oldDelegate.animationT != animationT ||
      oldDelegate.text != text ||
      oldDelegate.style != style;
}
