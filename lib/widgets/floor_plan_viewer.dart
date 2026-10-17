import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/route.dart';
import '../theme/app_colors.dart';
import 'live_floor_plan.dart';
import 'zoomable_view.dart';

/// A floor plan that fills all the space it is given, with zoom buttons.
///
/// Unlike [MapFrame] (a card the size of the picture) this is for big views:
/// the Map tab and the full-screen route map. The picture is letterboxed in
/// the view, and the view opens either on [focus] (fractions of the picture,
/// e.g. [routeFocus]) or, with [cover], zoomed so the plan fills the screen.
class FloorPlanViewer extends StatefulWidget {
  final String image;
  final double imageWidth;
  final double imageHeight;
  final List<IndoorPoint> route;
  final List<FloorPin> pins;
  final Color color;
  final MapPoint? person;
  final Rect? focus;
  final bool cover;

  /// Space to keep clear at the bottom for a sheet or card over the map; the
  /// zoom buttons sit above it.
  final double bottomInset;

  /// Show the + / - / fit buttons (off for small cards).
  final bool controls;

  /// Space to keep clear at the top (chips over the map); the compass sits
  /// below it.
  final double topInset;

  const FloorPlanViewer({
    super.key,
    required this.image,
    required this.imageWidth,
    required this.imageHeight,
    this.route = const [],
    this.pins = const [],
    this.color = AppColors.academic,
    this.person,
    this.focus,
    this.cover = false,
    this.bottomInset = 0,
    this.controls = true,
    this.topInset = 0,
  });

  @override
  State<FloorPlanViewer> createState() => FloorPlanViewerState();
}

class FloorPlanViewerState extends State<FloorPlanViewer> {
  final _zoomKey = GlobalKey<ZoomableViewState>();

  // Where the picture sits inside the view (letterbox), set on layout.
  Rect _picture = Rect.zero;
  Size _view = Size.zero;
  double _rotation = 0; // radians, for the compass

  /// Pan and zoom so the picture pixel (x, y) is in view, a little above the
  /// middle so a card at the bottom does not hide it.
  void showImagePoint(double x, double y) {
    if (_picture.isEmpty || _view.isEmpty) return;
    final point = Offset(
      _picture.left + x / widget.imageWidth * _picture.width,
      _picture.top + y / widget.imageHeight * _picture.height,
    );
    // Middle of the part of the view the bottom card does not cover.
    final visible = math.max(1.0, _view.height - widget.bottomInset);
    _zoomKey.currentState?.showPoint(
      point,
      minZoom: _coverScale() * 1.6,
      anchor: Offset(0.5, (visible * 0.45) / _view.height),
    );
  }

  /// Zoom at which the picture fills the view in both directions.
  double _coverScale() {
    if (_picture.isEmpty) return 1;
    return math.max(_view.width / _picture.width, _view.height / _picture.height);
  }

  /// [widget.focus] (fractions of the picture) as fractions of the view.
  Rect? _viewFocus() {
    if (_view.isEmpty) return null;
    final f = widget.focus;
    if (f != null) {
      return Rect.fromLTWH(
        (_picture.left + f.left * _picture.width) / _view.width,
        (_picture.top + f.top * _picture.height) / _view.height,
        f.width * _picture.width / _view.width,
        f.height * _picture.height / _view.height,
      );
    }
    if (widget.cover) {
      final s = _coverScale();
      return Rect.fromCenter(center: const Offset(0.5, 0.5), width: 1 / s, height: 1 / s);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _view = constraints.biggest;
        final aspect = widget.imageWidth / widget.imageHeight;
        var w = _view.width;
        var h = w / aspect;
        if (h > _view.height) {
          h = _view.height;
          w = h * aspect;
        }
        _picture = Rect.fromLTWH((_view.width - w) / 2, (_view.height - h) / 2, w, h);
        final focus = _viewFocus();

        return Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: Colors.white,
                child: ZoomableView(
                  key: _zoomKey,
                  focus: focus,
                  // A route gets a margin round it; "cover" fills exactly.
                  focusFill: widget.focus != null ? 0.85 : 1.0,
                  maxFocusScale: widget.focus != null ? 4.0 : 8.0,
                  maxScale: math.max(6.0, _coverScale() * 4),
                  onRotationChanged: (r) => setState(() => _rotation = r),
                  builder: (context, zoom, rotation) => Stack(
                    children: [
                      Positioned.fromRect(
                        rect: _picture,
                        child: LiveFloorPlan(
                          image: widget.image,
                          imageWidth: widget.imageWidth,
                          imageHeight: widget.imageHeight,
                          route: widget.route,
                          pins: widget.pins,
                          color: widget.color,
                          person: widget.person,
                          zoom: zoom,
                          rotation: rotation,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Shown while the plan is turned; tap to turn it back north-up.
            Positioned(
              right: 12,
              top: widget.topInset + 12,
              child: AnimatedScale(
                scale: _rotation.abs() > 0.01 ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: _Compass(
                  rotation: _rotation,
                  onTap: () => _zoomKey.currentState?.resetRotation(),
                ),
              ),
            ),
            if (widget.controls)
              Positioned(
              right: 12,
              bottom: widget.bottomInset + 16,
              child: _ZoomButtons(
                onIn: () => _zoomKey.currentState?.zoomBy(1.6),
                onOut: () => _zoomKey.currentState?.zoomBy(1 / 1.6),
                onFit: () {
                  final z = _zoomKey.currentState;
                  if (z == null) return;
                  // First press: back to the start view. Again: whole floor.
                  if (z.atHome) {
                    z.showAll();
                  } else {
                    z.reset();
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ZoomButtons extends StatelessWidget {
  final VoidCallback onIn;
  final VoidCallback onOut;
  final VoidCallback onFit;

  const _ZoomButtons({required this.onIn, required this.onOut, required this.onFit});

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tip, VoidCallback onTap) => SizedBox(
          width: 44,
          height: 44,
          child: IconButton(
            tooltip: tip,
            icon: Icon(icon, size: 22, color: AppColors.ink),
            onPressed: onTap,
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.white,
          elevation: 3,
          borderRadius: BorderRadius.circular(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              button(Icons.add, 'Zoom in', onIn),
              Container(width: 28, height: 1, color: AppColors.mist),
              button(Icons.remove, 'Zoom out', onOut),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Material(
          color: Colors.white,
          elevation: 3,
          shape: const CircleBorder(),
          child: button(Icons.fit_screen_outlined, 'Fit to screen', onFit),
        ),
      ],
    );
  }
}

/// A round button whose needle points to the top of the plan as drawn.
class _Compass extends StatelessWidget {
  final double rotation;
  final VoidCallback onTap;

  const _Compass({required this.rotation, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: 'Turn back north-up',
        onPressed: onTap,
        icon: Transform.rotate(
          angle: rotation,
          child: const Icon(Icons.navigation, size: 22, color: AppColors.danger),
        ),
      ),
    );
  }
}
