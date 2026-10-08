import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../models/route.dart';

/// Draws a route like a metro line: a coloured line with a white outline,
/// and optional "station" dots at every bend.
///
/// [progress] goes from 0 to 1 and draws only that fraction of the route,
/// which is how the line "draws itself" when it is animated.
class RoutePainter extends CustomPainter {
  final List<MapPoint> points;
  final double scale; // map units -> pixels
  final Color color;
  final double strokeWidth;
  final bool dots;
  final double progress;

  const RoutePainter({
    required this.points,
    required this.scale,
    required this.color,
    this.strokeWidth = 6,
    this.dots = false,
    this.progress = 1,
  });

  /// The first [t] (0..1) of a path's length.
  Path _partial(Path path, double t) {
    final result = Path();
    for (final metric in path.computeMetrics()) {
      result.addPath(metric.extractPath(0, metric.length * t), Offset.zero);
    }
    return result;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2 || progress <= 0) return;

    final full = Path()..moveTo(points.first.x * scale, points.first.y * scale);
    for (final p in points.skip(1)) {
      full.lineTo(p.x * scale, p.y * scale);
    }
    final path = progress >= 1 ? full : _partial(full, progress);

    final casing = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(path, casing);
    canvas.drawPath(path, line);

    if (dots) {
      // How far along the route each point is, so a dot appears only once
      // the line has reached it.
      final along = <double>[0];
      for (var i = 1; i < points.length; i++) {
        final dx = points[i].x - points[i - 1].x;
        final dy = points[i].y - points[i - 1].y;
        along.add(along.last + math.sqrt(dx * dx + dy * dy));
      }
      final total = along.last;

      final fill = Paint()..color = Colors.white;
      final ring = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      // Intermediate points only: the start and end have their own markers.
      for (var i = 1; i < points.length - 1; i++) {
        if (total > 0 && along[i] / total > progress) break;
        final centre = Offset(points[i].x * scale, points[i].y * scale);
        canvas.drawCircle(centre, strokeWidth * 0.95, fill);
        canvas.drawCircle(centre, strokeWidth * 0.95, ring);
      }
    }
  }

  @override
  bool shouldRepaint(RoutePainter old) =>
      old.points != points ||
      old.scale != scale ||
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.progress != progress;
}
