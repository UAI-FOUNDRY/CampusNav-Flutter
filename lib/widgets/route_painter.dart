import 'package:flutter/material.dart';
import '../models/route.dart';

/// Draws a route like a metro line: a coloured line with a white outline,
/// and optional "station" dots at every bend.
class RoutePainter extends CustomPainter {
  final List<MapPoint> points;
  final double scale; // map units -> pixels
  final Color color;
  final double strokeWidth;
  final bool dots;

  const RoutePainter({
    required this.points,
    required this.scale,
    required this.color,
    this.strokeWidth = 6,
    this.dots = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final path = Path()..moveTo(points.first.x * scale, points.first.y * scale);
    for (final p in points.skip(1)) {
      path.lineTo(p.x * scale, p.y * scale);
    }

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
      final fill = Paint()..color = Colors.white;
      final ring = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      // Intermediate points only: the start and end have their own markers.
      for (final p in points.skip(1).take(points.length - 2)) {
        final centre = Offset(p.x * scale, p.y * scale);
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
      old.strokeWidth != strokeWidth;
}
