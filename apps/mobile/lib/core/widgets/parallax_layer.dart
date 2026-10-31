import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Paints [child] shifted by its own position relative to the viewport
/// centre (times [scrollFactor]) plus the device tilt (times
/// [tiltAmplitude]). Stack several with different factors for a multi-layer
/// parallax — a larger factor lags more and reads as "further back".
///
/// The shift is applied at paint time, from the layout of the frame being
/// painted: a scroll or tilt change only repaints, it never rebuilds or
/// relayouts, and the offset is never a frame behind. The child is painted
/// straight onto the parent's canvas (no layer), so a blend-mode sibling
/// such as `BlendMask` still sees it as backdrop.
///
/// Inside a hidden branch (`TickerMode` off) the layer stops listening, so
/// an offstage screen costs nothing while the phone moves.
class ParallaxLayer extends SingleChildRenderObjectWidget {
  const ParallaxLayer({
    super.key,
    required this.scroll,
    required this.tilt,
    this.scrollFactor = 0,
    this.tiltAmplitude = Offset.zero,
    required Widget super.child,
  });

  /// Fires when the enclosing list scrolls (usually its `ScrollController`).
  final Listenable scroll;

  /// Normalised device tilt, each axis in ±1.
  final ValueListenable<Offset> tilt;

  /// Drift per pixel of the layer's offset from the viewport centre. A
  /// *positive* factor slides the layer **down** as you scroll further down
  /// the list (it lags, reading as "further back"); a *negative* factor
  /// leads. Bounded per layer — keyed to viewport position, not the absolute
  /// scroll offset.
  final double scrollFactor;

  /// Pixels of drift at full tilt.
  final Offset tiltAmplitude;

  @override
  RenderParallaxLayer createRenderObject(BuildContext context) =>
      RenderParallaxLayer(
        scroll: scroll,
        tilt: tilt,
        scrollFactor: scrollFactor,
        tiltAmplitude: tiltAmplitude,
        active: TickerMode.getValuesNotifier(context),
        viewportHeight: MediaQuery.sizeOf(context).height,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderParallaxLayer renderObject,
  ) {
    renderObject
      ..scroll = scroll
      ..tilt = tilt
      ..scrollFactor = scrollFactor
      ..tiltAmplitude = tiltAmplitude
      ..active = TickerMode.getValuesNotifier(context)
      ..viewportHeight = MediaQuery.sizeOf(context).height;
  }
}

class RenderParallaxLayer extends RenderProxyBox {
  RenderParallaxLayer({
    required Listenable scroll,
    required ValueListenable<Offset> tilt,
    required double scrollFactor,
    required Offset tiltAmplitude,
    required ValueListenable<TickerModeData> active,
    required double viewportHeight,
  }) : _scroll = scroll,
       _tilt = tilt,
       _scrollFactor = scrollFactor,
       _tiltAmplitude = tiltAmplitude,
       _active = active,
       _viewportHeight = viewportHeight;

  Listenable _scroll;
  set scroll(Listenable value) {
    if (identical(value, _scroll)) {
      return;
    }
    _unsubscribe();
    _scroll = value;
    _subscribe();
  }

  ValueListenable<Offset> _tilt;
  set tilt(ValueListenable<Offset> value) {
    if (identical(value, _tilt)) {
      return;
    }
    _unsubscribe();
    _tilt = value;
    _subscribe();
    markNeedsPaint();
  }

  double _scrollFactor;
  set scrollFactor(double value) {
    if (value == _scrollFactor) {
      return;
    }
    _scrollFactor = value;
    markNeedsPaint();
  }

  Offset _tiltAmplitude;
  set tiltAmplitude(Offset value) {
    if (value == _tiltAmplitude) {
      return;
    }
    _tiltAmplitude = value;
    markNeedsPaint();
  }

  ValueListenable<TickerModeData> _active;
  set active(ValueListenable<TickerModeData> value) {
    if (identical(value, _active)) {
      return;
    }
    _active.removeListener(_onActiveChanged);
    _unsubscribe();
    _active = value;
    if (attached) {
      _active.addListener(_onActiveChanged);
    }
    _subscribe();
  }

  double _viewportHeight;
  set viewportHeight(double value) {
    if (value == _viewportHeight) {
      return;
    }
    _viewportHeight = value;
    markNeedsPaint();
  }

  /// The shift used by the last paint, so hit testing matches what is on
  /// screen.
  Offset _shift = Offset.zero;

  bool _listening = false;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _active.addListener(_onActiveChanged);
    _subscribe();
  }

  @override
  void detach() {
    _active.removeListener(_onActiveChanged);
    _unsubscribe();
    super.detach();
  }

  void _subscribe() {
    if (_listening || !attached || !_active.value.enabled) {
      return;
    }
    _scroll.addListener(markNeedsPaint);
    _tilt.addListener(markNeedsPaint);
    _listening = true;
  }

  void _unsubscribe() {
    if (!_listening) {
      return;
    }
    _scroll.removeListener(markNeedsPaint);
    _tilt.removeListener(markNeedsPaint);
    _listening = false;
  }

  void _onActiveChanged() {
    if (_active.value.enabled) {
      _subscribe();
      // Catch up with whatever moved while the branch was hidden.
      markNeedsPaint();
    } else {
      _unsubscribe();
    }
  }

  /// Signed distance (px) from the viewport centre **up to** this layer's
  /// centre: positive while the layer sits above the centre, growing as the
  /// list scrolls down. Read from this frame's layout; the layer's own shift
  /// is applied to its child only, so it never feeds back into the
  /// measurement.
  double _viewportDelta() {
    final double centreY = localToGlobal(Offset.zero).dy + size.height / 2;
    return _viewportHeight / 2 - centreY;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) {
      return;
    }
    final Offset tilt = _tilt.value;
    _shift = Offset(
      tilt.dx * _tiltAmplitude.dx,
      _viewportDelta() * _scrollFactor + tilt.dy * _tiltAmplitude.dy,
    );
    context.paintChild(child, offset + _shift);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox? child = this.child;
    if (child == null) {
      return false;
    }
    return result.addWithPaintOffset(
      offset: _shift,
      position: position,
      hitTest: (BoxHitTestResult result, Offset transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_shift.dx, _shift.dy, 0, 1);
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DoubleProperty('scrollFactor', _scrollFactor))
      ..add(DiagnosticsProperty<Offset>('tiltAmplitude', _tiltAmplitude))
      ..add(DiagnosticsProperty<Offset>('shift', _shift));
  }
}
