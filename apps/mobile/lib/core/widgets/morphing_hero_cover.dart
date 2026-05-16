import 'dart:ui';

import 'package:flutter/material.dart';

/// Hero that morphs the cover image's clip shape between endpoints — circle
/// on the agenda tile, rounded rectangle on the detail screen.
///
/// The flight shuttle reads the current rendered size via [LayoutBuilder] and
/// computes the corner radius proportionally to that size, so the source end
/// always renders as a perfect circle and the destination as the requested
/// rounded rect. This avoids the "stadium snap" the earlier fixed-radius
/// lerp produced in mid-flight. We also use [MaterialRectArcTween] for the
/// rect motion so the cover sweeps along a smooth arc instead of a straight
/// line.
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
          MaterialRectArcTween(begin: begin, end: end),
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
    // Pop: skip the morph entirely (user gave up on it after several
    // iterations couldn't get the back trajectory to match the forward
    // one). Returning an empty shuttle hides the cover during the flight;
    // the default Navigator page transition handles the back gesture, and
    // the agenda's cover snaps in when the route is fully popped.
    if (direction == HeroFlightDirection.pop) {
      return const SizedBox.shrink();
    }
    // Defensive cast — in normal Flutter this never fails because Hero.child
    // is exactly what we passed in (`_CoverEndpoint`). Fall back to sane
    // defaults if the framework ever wraps it.
    BorderRadius beginRadius = const BorderRadius.all(Radius.circular(150));
    BorderRadius endRadius = const BorderRadius.all(Radius.circular(12));
    String? visualUrl = imageUrl;
    Widget visualFallback = fallback;
    BoxFit visualFit = fit;

    final Widget fromChild = (fromHeroContext.widget as Hero).child;
    final Widget toChild = (toHeroContext.widget as Hero).child;
    if (fromChild is _CoverEndpoint) {
      beginRadius = fromChild.borderRadius;
    }
    if (toChild is _CoverEndpoint) {
      endRadius = toChild.borderRadius;
      visualUrl = toChild.imageUrl;
      visualFallback = toChild.fallback;
      visualFit = toChild.fit;
    }

    // Why the "circle intent" endpoint is recomputed per frame:
    //   The static radius requested by the agenda is 150 — that's the right
    //   number for a 300×300 box only. As the shuttle's box morphs to the
    //   detail's wider rect, "150" no longer renders as a circle. If we
    //   lerp between two static radii and stop, the pop landing differs
    //   from the actual destination widget's clipping (which IS a perfect
    //   circle on the agenda) — and the user sees the shape snap at the
    //   end of the flight.
    //
    //   Fix: each frame, replace the larger of the two requested radii
    //   with `box.shortestSide / 2` for the current shuttle box. That keeps
    //   the "circle" side a true circle for whatever box size the Hero
    //   tween is showing at this instant. The landing matches the dest
    //   widget exactly; no blink.
    final bool circleIsBegin = beginRadius.topLeft.x >= endRadius.topLeft.x;
    final double rectIntent = circleIsBegin
        ? endRadius.topLeft.x
        : beginRadius.topLeft.x;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final double t = Curves.easeInOutCubic.transform(animation.value);
        return LayoutBuilder(
          builder: (context, constraints) {
            final double circleIntent = constraints.biggest.shortestSide / 2;
            final double from = circleIsBegin ? circleIntent : rectIntent;
            final double to = circleIsBegin ? rectIntent : circleIntent;
            final double radius = lerpDouble(from, to, t)!;
            return _CoverEndpoint(
              borderRadius: BorderRadius.circular(radius),
              imageUrl: visualUrl,
              fallback: visualFallback,
              fit: visualFit,
            );
          },
        );
      },
    );
  }
}

class _CoverEndpoint extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final bool has = imageUrl != null && imageUrl!.isNotEmpty;
    return ClipRRect(
      borderRadius: borderRadius,
      child: Container(
        color: const Color(0xFFEFEFEF),
        child: has
            ? Image.network(
                imageUrl!,
                fit: fit,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const SizedBox.shrink(),
                errorBuilder: (context, _, _) => fallback,
              )
            : fallback,
      ),
    );
  }
}
