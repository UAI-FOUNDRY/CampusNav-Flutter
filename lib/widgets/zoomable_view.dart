import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pinch / drag / double-tap zoom that tells its child the current zoom.
///
/// [InteractiveViewer] scales everything, so a 6 px route line becomes 24 px
/// at 4x and the floor plan disappears under it. Children built here get the
/// zoom and can divide their line widths and marker sizes by it, so the
/// picture gets bigger but the route stays crisp.
///
/// [focus] (fractions of the child, 0..1) opens the view zoomed onto that
/// part, e.g. the bounding box of an indoor route. Double-tap zooms in on the
/// tapped spot; double-tap again goes back to the starting view.
class ZoomableView extends StatefulWidget {
  final Widget Function(BuildContext context, double zoom) builder;
  final double minScale;
  final double maxScale;
  final Rect? focus;

  /// The most [focus] may zoom in, so a very short route keeps some context.
  final double maxFocusScale;

  /// How much of the screen [focus] fills: 0.85 leaves a margin round a
  /// route, 1 fills it exactly (e.g. "fill the height with the floor plan").
  final double focusFill;

  const ZoomableView({
    super.key,
    required this.builder,
    this.minScale = 1,
    this.maxScale = 6,
    this.focus,
    this.maxFocusScale = 3,
    this.focusFill = 0.85,
  });

  @override
  State<ZoomableView> createState() => ZoomableViewState();
}

/// Public so a parent with a GlobalKey can drive the zoom buttons.
class ZoomableViewState extends State<ZoomableView>
    with SingleTickerProviderStateMixin {
  final _controller = TransformationController();
  late final AnimationController _animation;
  Animation<Matrix4>? _tween;

  double _zoom = 1;
  Size _size = Size.zero;
  bool _focusApplied = false;
  bool _moved = false; // the user (or a button / showPoint) has moved the view
  Offset? _doubleTapAt;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTransform);
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(() {
        final t = _tween;
        if (t != null) _controller.value = t.value;
      });
  }

  @override
  void didUpdateWidget(ZoomableView old) {
    super.didUpdateWidget(old);
    // A new starting view (e.g. the screen got shorter when the keyboard
    // opened) is applied only if nobody has moved the view yet.
    if (old.focus != widget.focus && !_moved) _focusApplied = false;
  }

  @override
  void dispose() {
    _animation.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Rebuild the child only when the zoom really changes, not on every pan.
  void _onTransform() {
    final z = _controller.value.getMaxScaleOnAxis();
    if ((z - _zoom).abs() > 0.01) setState(() => _zoom = z);
  }

  /// A transform that shows the child at [scale] with [content] (a point in
  /// child coordinates) under [screen], kept inside the edges.
  Matrix4 _matrix(double scale, Offset content, Offset screen) {
    final s = scale.clamp(widget.minScale, widget.maxScale).toDouble();
    final w = _size.width;
    final h = _size.height;
    final tx = math.min(0.0, math.max(w - s * w, screen.dx - s * content.dx));
    final ty = math.min(0.0, math.max(h - s * h, screen.dy - s * content.dy));
    return Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(tx, ty, 0);
  }

  /// The starting view: fitted to [ZoomableView.focus], or the whole child.
  Matrix4 _home() {
    final f = widget.focus;
    if (f == null || _size.isEmpty) return Matrix4.identity();
    final fw = math.max(f.width, 0.05);
    final fh = math.max(f.height, 0.05);
    final s = math.min(widget.maxFocusScale, widget.focusFill * math.min(1 / fw, 1 / fh));
    if (s <= 1.05) return Matrix4.identity();
    final centre = Offset(f.center.dx * _size.width, f.center.dy * _size.height);
    return _matrix(s, centre, Offset(_size.width / 2, _size.height / 2));
  }

  void _animateTo(Matrix4 target) {
    _moved = true;
    _tween = Matrix4Tween(begin: _controller.value.clone(), end: target).animate(
      CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic),
    );
    _animation.forward(from: 0);
  }

  /// Current zoom (1 = the whole child fits).
  double get zoom => _controller.value.getMaxScaleOnAxis();

  /// Zoom in (factor > 1) or out around the middle of the view.
  void zoomBy(double factor) {
    if (_size.isEmpty) return;
    final middle = Offset(_size.width / 2, _size.height / 2);
    _animateTo(_matrix(zoom * factor, _controller.toScene(middle), middle));
  }

  /// Back to the starting view ([ZoomableView.focus], or everything).
  void reset() => _animateTo(_home());

  /// Zoomed all the way out: the whole child.
  void showAll() => _animateTo(Matrix4.identity());

  /// True when showing the starting view.
  bool get atHome => (zoom - _home().getMaxScaleOnAxis()).abs() < 0.05;

  /// Bring [point] (child coordinates) to [anchor] (fractions of the view,
  /// default the middle), zoomed to at least [minZoom].
  void showPoint(Offset point, {double minZoom = 2.5, Offset anchor = const Offset(0.5, 0.5)}) {
    if (_size.isEmpty) return;
    final s = math.max(zoom, minZoom);
    _animateTo(_matrix(s, point, Offset(anchor.dx * _size.width, anchor.dy * _size.height)));
  }

  void _onDoubleTap() {
    final tap = _doubleTapAt;
    if (!atHome || tap == null) {
      reset();
      return;
    }
    // Zoom in 2.5x more, keeping the tapped spot under the finger.
    final current = _controller.toScene(tap);
    _animateTo(_matrix(_controller.value.getMaxScaleOnAxis() * 2.5, current, tap));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        if (!_focusApplied && _size.isFinite && !_size.isEmpty) {
          _focusApplied = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _moved) return;
            _controller.value = _home();
          });
        }
        return GestureDetector(
          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
          onDoubleTap: _onDoubleTap,
          child: InteractiveViewer(
            transformationController: _controller,
            onInteractionStart: (_) => _moved = true,
            minScale: widget.minScale,
            maxScale: widget.maxScale,
            child: widget.builder(context, _zoom),
          ),
        );
      },
    );
  }
}

/// Line widths and marker sizes on a zoomable picture are multiplied by this.
/// At 1x it is 1. Zoomed in, things grow only a little on screen
/// (zoom^0.3: about 1.5x bigger at 4x) instead of 4x.
double zoomCompensation(double zoom) =>
    zoom <= 1 ? 1 : math.pow(zoom, 0.3).toDouble() / zoom;
