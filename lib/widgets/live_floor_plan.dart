import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/route.dart';
import '../services/live_guide.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import 'person_marker.dart';
import 'route_painter.dart';
import 'zoomable_view.dart';

/// A tappable dot on a floor plan (a place you can navigate to).
class FloorPin {
  final String label;
  final double x; // image pixels
  final double y;
  final VoidCallback onTap;

  /// The place picked on the map: a bigger dot with its name always shown.
  final bool selected;

  /// The place's line colour (null = the plan's colour) and its icon, shown
  /// inside the dot when it is selected.
  final Color? color;
  final IconData? icon;

  /// What a screen reader says, e.g. "AI Lab, lab, Block A". Defaults to
  /// [label].
  final String? semanticLabel;

  const FloorPin({
    required this.label,
    required this.x,
    required this.y,
    required this.onTap,
    this.selected = false,
    this.color,
    this.icon,
    this.semanticLabel,
  });
}

/// The part of a floor plan an indoor route covers, as fractions (0..1) of
/// the picture, with some room around it. Give it to [MapFrame.focus].
Rect? routeFocus(List<IndoorPoint> points, double imageWidth, double imageHeight) {
  if (points.isEmpty || imageWidth <= 0 || imageHeight <= 0) return null;
  var minX = points.first.x, maxX = minX, minY = points.first.y, maxY = minY;
  for (final p in points) {
    minX = math.min(minX, p.x);
    maxX = math.max(maxX, p.x);
    minY = math.min(minY, p.y);
    maxY = math.max(maxY, p.y);
  }
  // At least a fifth of the picture, so a short route keeps its surroundings.
  final w = math.max(maxX - minX, imageWidth * 0.2) + imageWidth * 0.08;
  final h = math.max(maxY - minY, imageHeight * 0.2) + imageHeight * 0.08;
  final cx = (minX + maxX) / 2;
  final cy = (minY + maxY) / 2;
  return Rect.fromCenter(
    center: Offset(cx / imageWidth, cy / imageHeight),
    width: w / imageWidth,
    height: h / imageHeight,
  );
}

/// A real floor-plan image with the route drawn on top.
///
/// Every x/y the backend sends is in IMAGE pixels, so the whole drawing is
/// scaled by `displayedWidth / imageWidth`. Put it inside a [MapFrame] whose
/// aspectRatio is imageWidth / imageHeight.
///
/// Pass the [zoom] from [MapFrame.builder] / [ZoomableView]: lines, dots and
/// markers are shrunk by it so zooming in shows more of the plan instead of
/// fatter lines.
///
/// The image must be bundled as `assets/floorplans/<image>` (see pubspec.yaml).
class LiveFloorPlan extends StatelessWidget {
  final String image; // file name from the backend, e.g. "ground.png"
  final double imageWidth;
  final double imageHeight;
  final List<IndoorPoint> route;
  final Color color;
  final List<FloorPin> pins;
  final double zoom;

  /// How far the view is rotated (radians). Markers and names are turned
  /// back by it so they stay upright while the plan turns.
  final double rotation;

  /// Where the user is right now (guidance), in image pixels. The person icon
  /// glides to each new position and the part of the line already walked turns
  /// grey. Null draws the plain route.
  final MapPoint? person;

  /// Live guidance: where you are, every frame (replaces [person]). The
  /// icon moves along the route continuously and shows the compass beam.
  final ValueListenable<LivePose?>? live;

  const LiveFloorPlan({
    super.key,
    required this.image,
    required this.imageWidth,
    required this.imageHeight,
    this.route = const [],
    this.color = AppColors.academic,
    this.pins = const [],
    this.person,
    this.live,
    this.zoom = 1,
    this.rotation = 0,
  });

  /// [pts] split where [me] is (on the nearest piece of the line):
  /// (walked part, part ahead, index of the last point already passed).
  static (List<MapPoint>, List<MapPoint>, int) _splitAt(List<MapPoint> pts, MapPoint me) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = pts[i], b = pts[i + 1];
      final dx = b.x - a.x, dy = b.y - a.y;
      final l2 = dx * dx + dy * dy;
      final t = l2 == 0 ? 0.0 : (((me.x - a.x) * dx + (me.y - a.y) * dy) / l2).clamp(0.0, 1.0).toDouble();
      final cx = a.x + t * dx, cy = a.y + t * dy;
      final d = (me.x - cx) * (me.x - cx) + (me.y - cy) * (me.y - cy);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return ([...pts.sublist(0, best + 1), me], [me, ...pts.sublist(best + 1)], best);
  }

  // Sizes on screen at 1x zoom.
  static const _line = 4.5;
  static const _casing = 8.0;
  static const _stop = 4.5; // station dot radius
  static const _pin = 16.0;
  static const _minStopGap = 34.0; // screen px between two station dots

  /// Station dots: named places the route passes, but never two so close on
  /// screen that they pile up (bends have no name and get no dot).
  List<bool> _stops(double screenPerPixel) {
    final flags = List<bool>.filled(route.length, false);
    if (route.length < 3) return flags;
    var last = route.first;
    final end = route.last;
    double gap(IndoorPoint a, IndoorPoint b) =>
        math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2)) * screenPerPixel;
    for (var i = 1; i < route.length - 1; i++) {
      final p = route[i];
      if (p.name.trim().isEmpty) continue;
      if (gap(p, last) < _minStopGap || gap(p, end) < _minStopGap) continue;
      flags[i] = true;
      last = p;
    }
    return flags;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final s = constraints.maxWidth / imageWidth;
        final k = zoomCompensation(zoom); // keeps overlays near screen size
        final points = [for (final p in route) MapPoint(p.x, p.y)];
        final stops = _stops(s * zoom);
        final me = person;

        // Guidance: split the route into walked and still-to-walk parts.
        var walked = <MapPoint>[];
        var ahead = points;
        var aheadStops = stops;
        if (me != null && points.length > 1) {
          var best = 0;
          var bestDistance = double.infinity;
          for (var i = 0; i < points.length; i++) {
            final dx = points[i].x - me.x;
            final dy = points[i].y - me.y;
            final d = dx * dx + dy * dy;
            if (d < bestDistance) {
              bestDistance = d;
              best = i;
            }
          }
          walked = [...points.sublist(0, best + 1), me];
          ahead = [me, ...points.sublist(best + 1)];
          aheadStops = [false, ...stops.sublist(best + 1)];
        }

        RoutePainter painter(List<MapPoint> pts, Color c,
                {List<bool>? stopFlags, double progress = 1}) =>
            RoutePainter(
              points: pts,
              scale: s,
              color: c,
              strokeWidth: _line * k,
              casingWidth: _casing * k,
              dots: stopFlags != null,
              stops: stopFlags,
              dotRadius: _stop * k,
              ringWidth: 2 * k,
              progress: progress,
            );

        final marker = PersonMarker(color: color, size: 26);
        final live = this.live;

        // Live guidance: the walked / ahead split and the icon change every
        // frame, so only they are rebuilt (not the picture and the pins).
        Widget liveLine() => ValueListenableBuilder<LivePose?>(
              valueListenable: live!,
              builder: (context, pose, _) {
                final at = pose?.plan;
                if (at == null || points.length < 2) {
                  return CustomPaint(painter: painter(points, color, stopFlags: stops));
                }
                final (gone, next, idx) = _splitAt(points, at);
                return Stack(
                  children: [
                    Positioned.fill(child: CustomPaint(painter: painter(gone, Colors.grey.shade500))),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: painter(next, color, stopFlags: [false, ...stops.sublist(idx + 1)]),
                      ),
                    ),
                  ],
                );
              },
            );

        Widget liveMarker() => ValueListenableBuilder<LivePose?>(
              valueListenable: live!,
              builder: (context, pose, _) {
                final at = pose?.plan;
                if (pose == null || at == null) return const SizedBox.shrink();
                final f = pose.planFacing;
                final icon = PersonMarker(
                  color: pose.offRoute ? AppColors.sportsInk : color,
                  size: 26,
                  facing: f == null ? null : f + rotation,
                );
                final box = f == null ? icon.outerSize : icon.beamSize;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: at.x * s - box / 2,
                      top: at.y * s - box / 2,
                      width: box,
                      height: box,
                      child: Semantics(
                        label: 'You are here',
                        child: Transform.rotate(
                          angle: -rotation,
                          child: Transform.scale(scale: k, child: icon),
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
        // "Reduce motion" in the phone's settings: no drawing / gliding.
        final still = MediaQuery.of(context).disableAnimations;
        // Names once the plan is drawn at least 1.5 screen px per picture px.
        final showLabels = s * zoom >= 1.5;
        // Category icons inside the dots once they are big enough to read,
        // so the kind of place never depends on colour alone.
        final showIcons = s * zoom >= 0.8;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Image.asset(
                'assets/floorplans/$image',
                excludeFromSemantics: true,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
                errorBuilder: (context, error, stack) => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Floor plan image missing.\nCopy it to assets/floorplans/.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
            if (live != null)
              Positioned.fill(child: liveLine()),
            if (live == null && walked.length > 1)
              Positioned.fill(
                child: CustomPaint(painter: painter(walked, Colors.grey.shade500)),
              ),
            if (live == null && me != null && ahead.length > 1)
              Positioned.fill(
                child: CustomPaint(painter: painter(ahead, color, stopFlags: aheadStops)),
              ),
            if (live == null && me == null && points.length > 1)
              Positioned.fill(
                child: Semantics(
                  label: 'Route on this floor from ${route.first.name.isEmpty ? 'the start' : route.first.name} '
                      'to ${route.last.name.isEmpty ? 'the destination' : route.last.name}',
                  child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: Duration(milliseconds: still ? 0 : 1200),
                  curve: Curves.easeInOut,
                  builder: (context, t, _) => CustomPaint(
                    painter: painter(points, color, stopFlags: stops, progress: t),
                  ),
                ),
                ),
              ),
            // The selected pin is drawn last, so it sits on top of the others.
            for (final pin in pins)
              if (!pin.selected) ..._pinWidgets(pin, s, k, showLabels, showIcons),
            for (final pin in pins)
              if (pin.selected) ..._pinWidgets(pin, s, k, true, true),
            // Start: a small dark dot.
            if (live == null && me == null && points.isNotEmpty)
              _at(
                points.first.x * s,
                points.first.y * s,
                size: 14,
                k: k,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.ink,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2.5),
                  ),
                ),
              ),
            // Destination: a pin whose tip sits on the door.
            if (points.length > 1)
              _at(
                points.last.x * s,
                points.last.y * s,
                size: 30,
                k: k,
                tip: true,
                child: Icon(
                  Icons.location_on,
                  size: 30,
                  color: color,
                  shadows: const [Shadow(color: Colors.white, blurRadius: 4)],
                ),
              ),
            // You are here, live: follows you frame by frame.
            if (live != null) Positioned.fill(child: liveMarker()),
            // You are here: slides smoothly from one step to the next.
            if (live == null && me != null)
              AnimatedPositioned(
                duration: Duration(milliseconds: still ? 0 : 1000),
                curve: Curves.easeInOut,
                left: me.x * s - marker.outerSize / 2,
                top: me.y * s - marker.outerSize / 2,
                width: marker.outerSize,
                height: marker.outerSize,
                child: Semantics(
                  label: 'You are here',
                  child: Transform.rotate(
                    angle: -rotation,
                    child: Transform.scale(scale: k, child: marker),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// A [size] x [size] widget centred on (x, y), or with its bottom centre on
  /// it when [tip] is true, shrunk by [k] around that anchor.
  Widget _at(double x, double y,
      {required double size, required double k, required Widget child, bool tip = false}) {
    return Positioned(
      left: x - size / 2,
      top: tip ? y - size : y - size / 2,
      width: size,
      height: size,
      child: Transform.rotate(
        angle: -rotation,
        alignment: tip ? Alignment.bottomCenter : Alignment.center,
        child: Transform.scale(
          scale: k,
          alignment: tip ? Alignment.bottomCenter : Alignment.center,
          child: child,
        ),
      ),
    );
  }

  List<Widget> _pinWidgets(FloorPin pin, double s, double k, bool showLabel, bool showIcon) {
    const hit = 44.0; // the minimum finger-sized tap area around the small dot
    final x = pin.x * s;
    final y = pin.y * s;
    final c = pin.color ?? color;
    final big = _pin + 12;
    final withIcon = showIcon && pin.icon != null;
    final size = pin.selected ? big : (withIcon ? _pin + 6 : _pin);
    return [
      _at(
        x,
        y,
        size: hit,
        k: k,
        child: Semantics(
          button: true,
          selected: pin.selected,
          label: pin.semanticLabel ?? pin.label,
          hint: pin.selected ? null : 'Shows this place',
          excludeSemantics: true,
          child: Tooltip(
          message: pin.label,
          excludeFromSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: pin.onTap,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: pin.selected ? 3 : 2),
                  boxShadow: [
                    const BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
                    // A soft halo in the line colour marks the picked place.
                    if (pin.selected)
                      BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 0, spreadRadius: 6),
                  ],
                ),
                child: withIcon
                    ? Icon(pin.icon, size: pin.selected ? 15 : 12, color: readableOnLine(c))
                    : null,
              ),
            ),
          ),
        ),
        ),
      ),
      // Names appear once zoomed in far enough for them to fit.
      if (showLabel)
        Positioned(
          left: x,
          top: y,
          child: IgnorePointer(
            // Anchored on the dot, turned upright, then moved right on screen
            // so it reads the same whichever way the plan is turned.
            child: Transform.rotate(
              angle: -rotation,
              alignment: Alignment.topLeft,
              child: Transform.scale(
                scale: k,
                alignment: Alignment.topLeft,
                child: Transform.translate(
                  offset: Offset(pin.selected ? 22 : 11, -9),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(6),
                      border: pin.selected ? Border.all(color: c, width: 1.5) : null,
                    ),
                    child: Text(
                      pin.label,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
  }
}
