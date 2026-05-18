import 'dart:ui';

import 'package:flutter/material.dart';

/// Hero that morphs the cover image's clip shape between endpoints —
/// circle on the agenda tile, full-bleed rectangle on the detail
/// screen.
///
/// **Push** (agenda → detail). The box uses a plain
/// [MaterialRectArcTween]; the source is already square so the shape
/// can hold a true circle throughout the flight while the radius lerps
/// down to 0 with the destination's sharp corners.
///
/// **Pop** (detail → agenda). A plain arc would force the box through
/// wide non-square sizes for almost the whole flight, leaving the
/// shape as a stadium until the very end and snapping to a circle on
/// the last frame. [_CoverHeroTween] splits the pop flight in two:
///
///   1. **Squarify** (first [_popSquareSplit] of the flight) — the
///      box shrinks in place from the detail rect to a `dest.size`
///      square anchored at the source's top edge. The radius lerps to
///      `shortestSide / 2` over the same window.
///   2. **Arc-move** — the now-square box arc-moves to the agenda
///      position with the radius held at the circle endpoint, which
///      on a square box renders as a clean circle.
///
/// Clipping is always a single [ClipRRect] so the swipe-back gesture's
/// value wiggle across a phase boundary can't blink between two clip
/// widget types.
class MorphingHeroCover extends StatelessWidget {
  const MorphingHeroCover({
    super.key,
    required this.tag,
    required this.imageUrl,
    required this.borderRadius,
    required this.fallback,
    this.fit = BoxFit.cover,
  });

  final Object tag;
  final String? imageUrl;
  final BorderRadius borderRadius;
  final Widget fallback;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: tag,
      createRectTween: (begin, end) =>
          _CoverHeroTween(begin: begin!, end: end!),
      flightShuttleBuilder: _flightShuttle,
      child: _CoverEndpoint(
        borderRadius: borderRadius,
        imageUrl: imageUrl,
        fallback: fallback,
        fit: fit,
      ),
    );
  }

  Widget _flightShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final _CoverEndpoint fromChild =
        (fromHeroContext.widget as Hero).child as _CoverEndpoint;
    final _CoverEndpoint toChild =
        (toHeroContext.widget as Hero).child as _CoverEndpoint;
    final double beginRadius = fromChild.borderRadius.topLeft.x;
    final double endRadius = toChild.borderRadius.topLeft.x;

    // The "circle side" of the morph is whichever endpoint asked for
    // the larger radius. We replace that side's static radius with the
    // current shuttle box's `shortestSide / 2` each frame so it stays
    // a true circle for whatever box the tween is producing — the
    // landing matches the destination widget's actual clip exactly.
    final bool circleIsBegin = beginRadius >= endRadius;
    final double rectIntent = circleIsBegin ? endRadius : beginRadius;
    final bool isPop = direction == HeroFlightDirection.pop;

    // Built once per flight — the per-frame [ClipRRect] is the only
    // thing that rebuilds, so the Image.network widget instance stays
    // stable across all 60+ frames.
    final Widget content = _CoverContent(
      imageUrl: toChild.imageUrl,
      fallback: toChild.fallback,
      fit: toChild.fit,
    );

    // Hero shuttles render in the navigator overlay without an
    // ancestor [Material]; wrap explicitly so clip + decoration code
    // paths don't fall back to platform defaults that can flash.
    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          // animation.value goes 0 → 1 forward for push, 1 → 0 for pop.
          // The tween's squarify phase always sits at the detail-end of
          // the tween's parameter, so for pop the shape morph window
          // is `1 - animation.value`. See [_CoverHeroTween].
          final double t;
          if (isPop) {
            final double phase = ((1.0 - animation.value) / _popSquareSplit)
                .clamp(0.0, 1.0);
            t = Curves.easeOutCubic.transform(phase);
          } else {
            t = Curves.easeInOutCubic.transform(animation.value);
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final double circleIntent = constraints.biggest.shortestSide / 2;
              final double from = circleIsBegin ? circleIntent : rectIntent;
              final double to = circleIsBegin ? rectIntent : circleIntent;
              final double radius = lerpDouble(from, to, t)!;
              return ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: content,
              );
            },
          );
        },
      ),
    );
  }
}

/// Fraction of the pop flight in which the box squarifies in place.
/// The remaining `1 - _popSquareSplit` arcs the square box to the
/// agenda position.
const double _popSquareSplit = 0.4;

class _CoverHeroTween extends RectTween {
  _CoverHeroTween({required Rect super.begin, required Rect super.end});

  /// True when `begin` is a clearly wider rectangle and `end` is a
  /// near-square endpoint — the shape that drives the pop morph.
  bool get _isWideToSquare {
    final double beginAspect = begin!.width / begin!.height;
    final double endAspect = end!.width / end!.height;
    return (beginAspect - 1.0).abs() > 0.15 && (endAspect - 1.0).abs() < 0.05;
  }

  /// A `dest.size` square horizontally centered on `begin` and
  /// anchored at `begin.top` — the intermediate rect at the end of
  /// the squarify phase.
  Rect get _squared {
    final Rect b = begin!;
    final Rect e = end!;
    return Rect.fromCenter(
      center: Offset(b.center.dx, b.top + e.height / 2),
      width: e.width,
      height: e.height,
    );
  }

  @override
  Rect lerp(double t) {
    if (!_isWideToSquare) {
      return MaterialRectArcTween(begin: begin, end: end).lerp(t);
    }
    final Rect squared = _squared;
    if (t <= _popSquareSplit) {
      return Rect.lerp(begin, squared, t / _popSquareSplit)!;
    }
    final double subT = (t - _popSquareSplit) / (1.0 - _popSquareSplit);
    return MaterialRectArcTween(begin: squared, end: end).lerp(subT);
  }
}

class _CoverEndpoint extends StatefulWidget {
  const _CoverEndpoint({
    required this.borderRadius,
    required this.imageUrl,
    required this.fallback,
    required this.fit,
  });

  final BorderRadius borderRadius;
  final String? imageUrl;
  final Widget fallback;
  final BoxFit fit;

  @override
  State<_CoverEndpoint> createState() => _CoverEndpointState();
}

class _CoverEndpointState extends State<_CoverEndpoint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _revealCtrl;
  bool _revealStarted = false;

  bool get _hasImage =>
      widget.imageUrl != null && widget.imageUrl!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Reveal scales the whole clipped cover from 0 → 1 once the image
    // is ready. With no image URL, the fallback shows immediately at
    // full size — there's nothing to wait for.
    _revealCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      value: _hasImage ? 0.0 : 1.0,
    );
  }

  @override
  void didUpdateWidget(covariant _CoverEndpoint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _revealStarted = false;
      _revealCtrl.value = _hasImage ? 0.0 : 1.0;
    }
  }

  @override
  void dispose() {
    _revealCtrl.dispose();
    super.dispose();
  }

  void _onImageReady() {
    if (_revealStarted || !mounted) return;
    _revealStarted = true;
    _revealCtrl.forward();
  }

  @override
  Widget build(BuildContext context) {
    final Widget child = ClipRRect(
      borderRadius: widget.borderRadius,
      child: _CoverContent(
        imageUrl: widget.imageUrl,
        fallback: widget.fallback,
        fit: widget.fit,
        onImageReady: _onImageReady,
      ),
    );
    return AnimatedBuilder(
      animation: _revealCtrl,
      builder: (BuildContext context, Widget? c) {
        final double scale = Curves.easeOutCubic.transform(_revealCtrl.value);
        return Transform.scale(scale: scale, child: c);
      },
      child: child,
    );
  }
}

/// Unclipped image + fallback. Shared by [_CoverEndpoint] and the
/// flight shuttle so the per-frame [ClipRRect] in the shuttle wraps
/// the same widget instance every frame.
class _CoverContent extends StatelessWidget {
  const _CoverContent({
    required this.imageUrl,
    required this.fallback,
    required this.fit,
    this.onImageReady,
  });

  final String? imageUrl;
  final Widget fallback;
  final BoxFit fit;

  /// Fires once the underlying [Image.network] has its first decoded
  /// frame ready. Used by [_CoverEndpointState] to drive the reveal
  /// scale-in. The flight shuttle passes `null` here — its scale stays
  /// at 1 throughout the hero animation.
  final VoidCallback? onImageReady;

  @override
  Widget build(BuildContext context) {
    final bool has = imageUrl != null && imageUrl!.isNotEmpty;
    return Container(
      color: const Color(0xFFEFEFEF),
      child: has
          ? Image.network(
              imageUrl!,
              fit: fit,
              frameBuilder:
                  (
                    BuildContext context,
                    Widget child,
                    int? frame,
                    bool wasSynchronouslyLoaded,
                  ) {
                    if (onImageReady != null &&
                        (wasSynchronouslyLoaded || frame != null)) {
                      // Defer to next frame so the parent's setState /
                      // controller.forward() doesn't fire mid-build.
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        onImageReady!();
                      });
                    }
                    return child;
                  },
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : const SizedBox.shrink(),
              errorBuilder: (context, _, _) => fallback,
            )
          : fallback,
    );
  }
}
