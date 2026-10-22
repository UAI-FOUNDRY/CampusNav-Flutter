import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/destination_style.dart';

/// "You are here": your person icon on a coloured disc with a soft halo,
/// like the blue dot in Google Maps. The icon is assets/icons/person.png.
///
/// With [facing] (radians, clockwise from the top of the screen) a beam
/// shows which way the phone points, like Google Maps' blue cone.
class PersonMarker extends StatelessWidget {
  final Color color;
  final double size;
  final double? facing;

  const PersonMarker({super.key, required this.color, this.size = 36, this.facing});

  /// The marker is bigger than the disc because of the halo.
  double get outerSize => size * 1.6;

  /// Room needed when the beam is shown.
  double get beamSize => size * 2.7;

  @override
  Widget build(BuildContext context) {
    final f = facing;
    final disc = SizedBox(
      width: outerSize,
      height: outerSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: outerSize,
            height: outerSize,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.22),
              shape: BoxShape.circle,
            ),
          ),
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
              ],
            ),
            child: Center(
              child: Image.asset(
                'assets/icons/person.png',
                width: size * 0.5,
                height: size * 0.5,
                color: readableOnLine(color),
                colorBlendMode: BlendMode.srcIn,
              ),
            ),
          ),
        ],
      ),
    );
    if (f == null) return disc;
    return SizedBox(
      width: beamSize,
      height: beamSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _BeamPainter(color: color, angle: f)),
            ),
          ),
          disc,
        ],
      ),
    );
  }
}

/// A soft wedge from the centre towards [angle].
class _BeamPainter extends CustomPainter {
  final Color color;
  final double angle; // radians, clockwise from up

  const _BeamPainter({required this.color, required this.angle});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    const half = 35 * math.pi / 180;
    // Canvas angles start at "right" (east); "up" is -pi/2.
    final start = angle - math.pi / 2 - half;
    final rect = Rect.fromCircle(center: c, radius: r);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: 0.45), color.withValues(alpha: 0.0)],
      ).createShader(rect);
    canvas.drawArc(rect, start, 2 * half, true, paint);
  }

  @override
  bool shouldRepaint(_BeamPainter old) => old.angle != angle || old.color != color;
}
