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

  /// Told when the user starts moving the view by hand (e.g. to stop
  /// following the person icon).
  final VoidCallback? onInteract;

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
    this.onInteract,
  });

  @override
  State<ZoomableView> createState() => ZoomableViewState();
}

/// Public so a parent with a GlobalKey can drive the zoom / compass buttons.
///
/// Gestures follow Google Maps:
/// - one finger drags; let go while moving and the map glides to a stop;
/// - two fingers pinch to zoom and move at the same time;
/// - a two-finger twist only starts turning the map after about 15 degrees
///   (35 if you are clearly zooming), and then follows your fingers from
///   there without a jump; zoom keeps working while you turn;
/// - double-tap zooms in, double-tap-and-drag zooms with one finger
///   (drag down = in, up = out), two-finger tap zooms out;
/// - the map does not snap back north; the compass does that.
class ZoomableViewState extends State<ZoomableView>
    with SingleTickerProviderStateMixin {
  static const _rotateThreshold = 15 * math.pi / 180;
  static const _rotateThresholdWhileZooming = 35 * math.pi / 180;
  static const _zoomDeadZone = 0.03; // ln(scale): ignore 3 % finger jitter
  static const _zoomLock = 0.12; // ln(scale): past ~12 % it is "a zoom"
  static const _flingMinSpeed = 350.0; // px/s
  static const _quickZoomTime = Duration(milliseconds: 300);

  final _matrix = ValueNotifier<Matrix4>(Matrix4.identity());
  late final AnimationController _animation;
  Animation<Matrix4>? _tween;

  double _zoom = 1;
  double _rotation = 0;
  Size _size = Size.zero;
  bool _focusApplied = false;
  bool _moved = false; // the user (or a button / showPoint) has moved the view
  Offset? _doubleTapAt;

  // ---- the two-finger gesture in progress ----
  double _lastScale = 1;
  double _lastRotation = 0;
  Offset _lastFocal = Offset.zero;
  int _lastPointers = 0;
  int _maxPointers = 0; // fingers down at once since the last all-up (taps)
  int _gestureFingers = 0; // most fingers in the current drag (fling)
  double _rawLogScale = 0; // how much the fingers have pinched in total
  double _rawRotation = 0; // and twisted, before anything was applied
  bool _zoomOn = false;
  bool _zoomLocked = false;
  bool _twisting = false;

  // ---- raw pointers: quick zoom and two-finger tap ----
  int _pointers = 0;
  Offset? _downAt;
  DateTime? _downTime;
  DateTime? _lastTapUp;
  Offset? _lastTapUpAt;
  bool _quick = false; // double-tap-and-drag zoom in progress
  bool _quickMoved = false;
  Offset _quickAnchor = Offset.zero;
  double _quickStartY = 0;
  Matrix4 _quickStart = Matrix4.identity();
  bool _skipDoubleTap = false;
  // Raw pointer events arrive before the gesture callbacks, so the scale
  // end of a drag-zoom comes after _quick is cleared; this remembers it.
  bool _quickEnding = false;
  DateTime? _twoDown;
  double _twoTravel = 0;

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

  /// Where the child point [child] is on screen right now.
  Offset toScreen(Offset child) => MatrixUtils.transformPoint(_matrix.value, child);

  /// True while an animation (zoom button, showPoint ...) is running.
  bool get animating => _animation.isAnimating;

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

  /// [m] changed on screen: scaled by [scale] and turned by [angle] around
  /// [pivot], after moving by [shift].
  static Matrix4 _around(Matrix4 m, Offset pivot, {double scale = 1, double angle = 0, Offset shift = Offset.zero}) =>
      Matrix4.translationValues(pivot.dx, pivot.dy, 0)
        ..multiply(Matrix4.rotationZ(angle))
        ..multiply(Matrix4.diagonal3Values(scale, scale, 1))
        ..multiply(Matrix4.translationValues(shift.dx - pivot.dx, shift.dy - pivot.dy, 0))
        ..multiply(m);

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

  void _animateTo(
    Matrix4 target, {
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.easeOutCubic,
  }) {
    _moved = true;
    _animation.duration = duration;
    _tween = Matrix4Tween(begin: _matrix.value.clone(), end: target).animate(
      CurvedAnimation(parent: _animation, curve: curve),
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
    _animateTo(
      _keepInside(_place(_toChild(_middle), _middle, zoom, 0)),
      duration: const Duration(milliseconds: 400),
    );
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

  // ---- drag / pinch / twist ----

  /// Smallest equivalent angle, so a twist past 180 degrees does not jump.
  static double _wrap(double a) {
    while (a > math.pi) {
      a -= 2 * math.pi;
    }
    while (a < -math.pi) {
      a += 2 * math.pi;
    }
    return a;
  }

  void _onScaleStart(ScaleStartDetails d) {
    _animation.stop();
    _moved = true;
    widget.onInteract?.call();
    _lastScale = 1;
    _lastRotation = 0;
    _lastFocal = d.localFocalPoint;
    _lastPointers = d.pointerCount;
    _gestureFingers = d.pointerCount;
    _rawLogScale = 0;
    _rawRotation = 0;
    _zoomOn = false;
    _zoomLocked = false;
    _twisting = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_quick || _quickEnding) return; // the one-finger zoom owns this gesture

    // A finger was added or lifted: Flutter restarts scale and rotation from
    // here, so take new reference values and move nothing this frame.
    if (d.pointerCount != _lastPointers) {
      _lastPointers = d.pointerCount;
      _gestureFingers = math.max(_gestureFingers, d.pointerCount);
      _lastScale = d.scale;
      _lastRotation = d.rotation;
      _lastFocal = d.localFocalPoint;
      return;
    }

    final ds = _lastScale > 0 ? d.scale / _lastScale : 1.0;
    final dr = _wrap(d.rotation - _lastRotation);
    final shift = d.localFocalPoint - _lastFocal;
    _lastScale = d.scale;
    _lastRotation = d.rotation;
    _lastFocal = d.localFocalPoint;

    var applyScale = 1.0;
    var applyAngle = 0.0;
    if (d.pointerCount >= 2) {
      _rawLogScale += math.log(ds);
      _rawRotation += dr;

      // Decide what the fingers are doing. Changes start from the moment
      // they are recognised, so nothing jumps when they kick in.
      if (!_zoomOn && _rawLogScale.abs() > _zoomDeadZone) {
        _zoomOn = true;
      } else if (_zoomOn) {
        applyScale = ds;
      }
      if (!_twisting && _rawLogScale.abs() > _zoomLock) _zoomLocked = true;
      if (widget.rotate && !_twisting) {
        final need = _zoomLocked ? _rotateThresholdWhileZooming : _rotateThreshold;
        if (_rawRotation.abs() > need) _twisting = true;
      } else if (_twisting) {
        applyAngle = dr;
      }
    }

    final current = _matrix.value;
    final z = zoom;
    final s = _clampZoom(z * applyScale) / z;
    final m = _around(current, d.localFocalPoint, scale: s, angle: applyAngle, shift: shift);
    _matrix.value = _keepInside(m);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_quick || _quickEnding) {
      _quickEnding = false;
      return;
    }
    // Let go while dragging with one finger: glide to a stop.
    final v = d.velocity.pixelsPerSecond;
    if (_gestureFingers == 1 && v.distance > _flingMinSpeed) {
      final glide = v * 0.22; // about how far Google Maps coasts
      _animateTo(
        _keepInside(_around(_matrix.value, Offset.zero, shift: glide)),
        duration: const Duration(milliseconds: 650),
        curve: Curves.decelerate,
      );
    }
  }

  void _onDoubleTap() {
    if (_skipDoubleTap) {
      _skipDoubleTap = false;
      return;
    }
    final tap = _doubleTapAt;
    if (!atHome || tap == null) {
      reset();
      return;
    }
    _zoomAround(tap, 2.5); // keeps the tapped spot under the finger
  }

  // ---- raw pointers: double-tap-and-drag zoom, two-finger tap ----

  void _onPointerDown(PointerDownEvent e) {
    _pointers++;
    final now = DateTime.now();
    _maxPointers = math.max(_maxPointers, _pointers);
    if (_pointers == 1) {
      _skipDoubleTap = false;
      _quickEnding = false;
      _downAt = e.localPosition;
      _downTime = now;
      final t = _lastTapUp;
      final at = _lastTapUpAt;
      if (t != null &&
          at != null &&
          now.difference(t) < _quickZoomTime &&
          (e.localPosition - at).distance < 40) {
        // Second tap: if this finger now moves up or down, it zooms.
        _quick = true;
        _quickMoved = false;
        _quickAnchor = e.localPosition;
        _quickStartY = e.localPosition.dy;
        _quickStart = _matrix.value.clone();
        _animation.stop();
      }
    } else {
      _quick = false;
    }
    if (_pointers == 2) {
      _twoDown = now;
      _twoTravel = 0;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_pointers >= 2) _twoTravel += e.delta.distance;
    if (!_quick || _pointers != 1) return;
    final dy = e.localPosition.dy - _quickStartY;
    if (!_quickMoved && dy.abs() > 8) _quickMoved = true;
    if (!_quickMoved) return;
    _moved = true;
    // Drag down zooms in, up zooms out, like Google Maps.
    final start = _scaleOf(_quickStart);
    final s = _clampZoom(start * math.exp(dy / 160)) / start;
    _matrix.value = _keepInside(_around(_quickStart, _quickAnchor, scale: s));
  }

  void _onPointerUp(PointerUpEvent e) {
    final now = DateTime.now();
    // Two fingers tapped together (no drag): zoom out one step.
    final two = _twoDown;
    if (_pointers == 2 &&
        two != null &&
        now.difference(two) < const Duration(milliseconds: 300) &&
        _twoTravel < 24) {
      zoomBy(0.5);
    }
    if (_pointers == 2) _twoDown = null;

    _pointers = math.max(0, _pointers - 1);
    if (_pointers > 0) return;

    if (_quick) {
      // A drag-zoom is not also a double-tap.
      if (_quickMoved) _skipDoubleTap = true;
      _quick = false;
      _quickEnding = true;
      _lastTapUp = null;
      _maxPointers = 0;
      return;
    }
    final down = _downTime;
    final at = _downAt;
    final wasTap = down != null &&
        at != null &&
        _maxPointers <= 1 &&
        now.difference(down) < const Duration(milliseconds: 250) &&
        (e.localPosition - at).distance < 20;
    _lastTapUp = wasTap ? now : null;
    _lastTapUpAt = wasTap ? e.localPosition : null;
    _maxPointers = 0;
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers == 0) {
      _quick = false;
      _maxPointers = 0;
    }
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
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
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
