import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Paints [child] into its own layer and composites it onto whatever was
/// already drawn behind it using [blendMode] (default [BlendMode.difference]).
///
/// With white content over a photo, `difference` inverts the backdrop, so the
/// text stays legible over both bright and dark areas — useful for the small
/// date/time row that overlaps the dark cover circle on the agenda card.
///
/// Caveat: the backdrop must land on the *same* canvas before this widget —
/// e.g. an earlier sibling in a [Stack]. A [RepaintBoundary], [Opacity] or
/// filter layer between the two isolates them and the blend reads emptiness.
class BlendMask extends SingleChildRenderObjectWidget {
  const BlendMask({
    super.key,
    required Widget super.child,
    this.blendMode = BlendMode.difference,
  });

  final BlendMode blendMode;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBlendMask(blendMode);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderBlendMask).blendMode = blendMode;
  }
}

class _RenderBlendMask extends RenderProxyBox {
  _RenderBlendMask(this._blendMode);

  BlendMode _blendMode;
  set blendMode(BlendMode value) {
    if (_blendMode == value) {
      return;
    }
    _blendMode = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      return;
    }
    context.canvas.saveLayer(offset & size, Paint()..blendMode = _blendMode);
    super.paint(context, offset);
    context.canvas.restore();
  }
}
