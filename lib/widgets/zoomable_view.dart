import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Pinch to zoom, two-finger twist to rotate, drag to move, double-tap to
/// zoom, and tell the child the current zoom and rotation.
///
/// (Flutter's InteractiveViewer cannot rotate, so the gestures are handled
/// here.) The child is laid out at the view's size and transformed. Children
/// get the zoom so they can divide line widths and marker sizes by it (see
/// [zoomCompensation]), and the rotation so markers and names can be turned
/// back upright.
///
/// [focus] (fractions of the child, 0..1) opens the view zoomed onto that
/// part, e.g. the bounding box of an indoor route. Double-tap zooms in on the
/// tapped spot; double-tap again goes back to the starting view.
class ZoomableView extends StatefulWidget {
  final Widget Function(BuildContext context, double zoom, double rotation) builder;
  final double minScale;
  final double maxScale;
  final Rect? focus;

  /// The most [focus] may zoom in, so a very short route keeps some context.
  final double maxFocusScale;

  /// How much of the screen [focus] fills: 0.85 leaves a margin round a
  /// route, 1 fills it exactly (e.g. "fill the height with the floor plan").
  final double focusFill;

  /// Allow turning with two fingers.
  final bool rotate;

  /// Told whenever the rotation changes (radians), e.g. for a compass button.
  final ValueChanged<double>? onRotationChanged;

  const ZoomableView({
    super.key,
    required this.builder,
    this.minScale = 1,
    this.maxScale = 6,
    this.focus,
    this.maxFocusScale = 3,
    this.focusFill = 0.85,
    this.rotate = true,
    this.onRotationChanged,
  });

  @override
  State<ZoomableView> createState() => ZoomableViewState();
}

/// Public so a parent with a GlobalKey can drive the zoom / compass buttons.
class ZoomableViewState extends State<ZoomableView>
    with SingleTickerProviderStateMixin {
  // A twist smaller than this (radians, about 7 degrees) is ignored, so a
  // plain pinch does not turn the map by accident.
  static const _rotateDeadZone = 0.12;
  // Let go within this of north and the map snaps straight (about 6 degrees).
  static const _snapToNorth = 0.1;

  final _matrix = ValueNotifier<Matrix4>(Matrix4.identity());
  late final AnimationController _animation;
  Animation<Matrix4>? _tween;

  double _zoom = 1;
  double _rotation = 0;
  Size _size = Size.zero;
  bool _focusApplied = false;
  bool _moved = false; // the user (or a button / showPoint) has moved the view
  Offset? _doubleTapAt;

  // The gesture in progress.
  Matrix4? _startMatrix;
  Offset _startFocal = Offset.zero;
  double _startZoom = 1;
  bool _twisting = false;
  double _twistOffset = 0;

  @override
  void initState() {
    super.initState();
    _matrix.addListener(_onTransform);
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(() {
        final t = _tween;
        if (t != null) _matrix.value = t.value;
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
    _matrix.dispose();
    super.dispose();
  }

  // ---- reading the transform ----

  static double _scaleOf(Matrix4 m) => m.getMaxScaleOnAxis();
  static double _angleOf(Matrix4 m) => math.atan2(m.entry(1, 0), m.entry(0, 0));

  /// Current zoom (1 = the whole child fits).
  double get zoom => _scaleOf(_matrix.value);

  /// Current rotation in radians (0 = north up / as drawn).
  double get rotation => _angleOf(_matrix.value);

  /// Rebuild the child only when zoom or rotation really change, not on pans.
  void _onTransform() {
    final z = zoom;
    final r = rotation;
    final zoomChanged = (z - _zoom).abs() > 0.01;
    final turned = (r - _rotation).abs() > 0.005;
    if (zoomChanged || turned) {
      setState(() {
        _zoom = z;
        _rotation = r;
      });
      if (turned) widget.onRotationChanged?.call(r);
    }
  }

  // ---- building transforms ----

  Offset get _middle => Offset(_size.width / 2, _size.height / 2);

  /// Child [content] point drawn at screen [at], turned by [angle], at [scale].
  static Matrix4 _place(Offset content, Offset at, double scale, double angle) =>
      Matrix4.translationValues(at.dx, at.dy, 0)
        ..multiply(Matrix4.rotationZ(angle))
        ..multiply(Matrix4.diagonal3Values(scale, scale, 1))
        ..multiply(Matrix4.translationValues(-content.dx, -content.dy, 0));

  /// Which child point is under [screen] right now.
  Offset _toChild(Offset screen, [Matrix4? m]) =>
      MatrixUtils.transformPoint(Matrix4.inverted(m ?? _matrix.value), screen);

  /// Keep the plan on screen: the child point under the middle of the view
  /// may not go closer to the edge than half a screen (so at 1x nothing
  /// moves, and zoomed in you can reach every corner but not drag it away).
  Matrix4 _keepInside(Matrix4 m) {
    if (_size.isEmpty) return m;
    final s = _scaleOf(m);
    final p = _toChild(_middle, m);
    final hx = math.min(_size.width / 2, _size.width / (2 * s));
    final hy = math.min(_size.height / 2, _size.height / (2 * s));
    final clamped = Offset(
      p.dx.clamp(hx, _size.width - hx).toDouble(),
      p.dy.clamp(hy, _size.height - hy).toDouble(),
    );
    if (clamped == p) return m;
    final now = MatrixUtils.transformPoint(m, clamped);
    final shift = _middle - now;
    return Matrix4.translationValues(shift.dx, shift.dy, 0)..multiply(m);
  }

  double _clampZoom(double z) => z.clamp(widget.minScale, widget.maxScale).toDouble();

  /// The starting view: fitted to [ZoomableView.focus] (straight, not turned),
  /// or the whole child.
  Matrix4 _home() {
    final f = widget.focus;
    if (f == null || _size.isEmpty) return Matrix4.identity();
    final fw = math.max(f.width, 0.05);
    final fh = math.max(f.height, 0.05);
    final s = math.min(widget.maxFocusScale, widget.focusFill * math.min(1 / fw, 1 / fh));
    if (s <= 1.05) return Matrix4.identity();
    final centre = Offset(f.center.dx * _size.width, f.center.dy * _size.height);
    return _keepInside(_place(centre, _middle, _clampZoom(s), 0));
  }

  void _animateTo(Matrix4 target) {
    _moved = true;
    _tween = Matrix4Tween(begin: _matrix.value.clone(), end: target).animate(
      CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic),
    );
    _animation.forward(from: 0);
  }

  // ---- public controls (zoom buttons, compass, "show this place") ----

  /// Zoom in (factor > 1) or out around the middle of the view.
  void zoomBy(double factor) => _zoomAround(_middle, factor);

  void _zoomAround(Offset screen, double factor) {
    if (_size.isEmpty) return;
    final z = _clampZoom(zoom * factor);
    _animateTo(_keepInside(_place(_toChild(screen), screen, z, rotation)));
  }

  /// Back to the starting view ([ZoomableView.focus], or everything), straight.
  void reset() => _animateTo(_home());

  /// Zoomed all the way out and straight: the whole child.
  void showAll() => _animateTo(Matrix4.identity());

  /// Turn back to north-up, keeping the same spot in the middle.
  void resetRotation() {
    if (_size.isEmpty) return;
    _animateTo(_keepInside(_place(_toChild(_middle), _middle, zoom, 0)));
  }

  /// True when showing the starting view.
  bool get atHome =>
      (zoom - _scaleOf(_home())).abs() < 0.05 && rotation.abs() < 0.01;

  /// Bring [point] (child coordinates) to [anchor] (fractions of the view,
  /// default the middle), zoomed to at least [minZoom]. Keeps the rotation.
  void showPoint(Offset point, {double minZoom = 2.5, Offset anchor = const Offset(0.5, 0.5)}) {
    if (_size.isEmpty) return;
    final z = _clampZoom(math.max(zoom, minZoom));
    final at = Offset(anchor.dx * _size.width, anchor.dy * _size.height);
    _animateTo(_keepInside(_place(point, at, z, rotation)));
  }

  // ---- gestures ----

  void _onScaleStart(ScaleStartDetails d) {
    _animation.stop();
    _moved = true;
    _startMatrix = _matrix.value.clone();
    _startFocal = d.localFocalPoint;
    _startZoom = zoom;
    _twisting = false;
    _twistOffset = 0;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final start = _startMatrix;
    if (start == null) return;
    final f = _clampZoom(_startZoom * d.scale) / _startZoom;

    var angle = 0.0;
    if (widget.rotate && d.pointerCount >= 2) {
      if (!_twisting && d.rotation.abs() > _rotateDeadZone) {
        _twisting = true;
        _twistOffset = d.rotation.sign * _rotateDeadZone; // no jump when it starts
      }
      if (_twisting) angle = d.rotation - _twistOffset;
    }

    final m = Matrix4.translationValues(d.localFocalPoint.dx, d.localFocalPoint.dy, 0)
      ..multiply(Matrix4.rotationZ(angle))
      ..multiply(Matrix4.diagonal3Values(f, f, 1))
      ..multiply(Matrix4.translationValues(-_startFocal.dx, -_startFocal.dy, 0))
      ..multiply(start);
    _matrix.value = _keepInside(m);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _startMatrix = null;
    final r = rotation;
    if (widget.rotate && r != 0 && r.abs() < _snapToNorth) resetRotation();
  }

  void _onDoubleTap() {
    final tap = _doubleTapAt;
    if (!atHome || tap == null) {
      reset();
      return;
    }
    _zoomAround(tap, 2.5); // keeps the tapped spot under the finger
  }

  /// Mouse wheel / trackpad scroll (emulator, desktop): zoom at the pointer.
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
      _zoomAround(e.localPosition, e.scrollDelta.dy < 0 ? 1.25 : 0.8);
    }
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
            _matrix.value = _home();
          });
        }
        return Listener(
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
            onDoubleTap: _onDoubleTap,
            child: ClipRect(
              child: ValueListenableBuilder<Matrix4>(
                valueListenable: _matrix,
                builder: (context, m, child) => Transform(transform: m, child: child),
                child: SizedBox.fromSize(
                  size: _size,
                  child: widget.builder(context, _zoom, _rotation),
                ),
              ),
            ),
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
