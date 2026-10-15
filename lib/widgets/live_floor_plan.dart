import 'package:flutter/material.dart';

import '../models/route.dart';
import '../theme/app_colors.dart';
import 'route_painter.dart';

/// A tappable dot on a floor plan (a place you can navigate to).
class FloorPin {
  final String label;
  final double x; // image pixels
  final double y;
  final VoidCallback onTap;

  const FloorPin({
    required this.label,
    required this.x,
    required this.y,
    required this.onTap,
  });
}

/// A real floor-plan image with the route drawn on top.
///
/// Every x/y the backend sends is in IMAGE pixels, so the whole drawing is
/// scaled by `displayedWidth / imageWidth`. Put it inside a [MapFrame] whose
/// aspectRatio is imageWidth / imageHeight.
///
/// The image must be bundled as assets/floorplans/<image> (see pubspec.yaml).
class LiveFloorPlan extends StatelessWidget {
  final String image; // file name from the backend, e.g. "ground.png"
  final double imageWidth;
  final double imageHeight;
  final List<IndoorPoint> route;
  final Color color;
  final List<FloorPin> pins;

  const LiveFloorPlan({
    super.key,
    required this.image,
    required this.imageWidth,
    required this.imageHeight,
    this.route = const [],
    this.color = AppColors.academic,
    this.pins = const [],
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final s = constraints.maxWidth / imageWidth;
        final points = [for (final p in route) MapPoint(p.x, p.y)];

        return Stack(
          children: [
            Positioned.fill(
              child: Image.asset(
                'assets/floorplans/$image',
                fit: BoxFit.fill,
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
            if (points.length > 1)
              Positioned.fill(
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 1200),
                  curve: Curves.easeInOut,
                  builder: (context, t, _) => CustomPaint(
                    painter: RoutePainter(
                      points: points,
                      scale: s,
                      color: color,
                      strokeWidth: 6,
                      dots: true,
                      progress: t,
                    ),
                  ),
                ),
              ),
            for (final pin in pins)
              Positioned(
                left: pin.x * s - 11,
                top: pin.y * s - 11,
                width: 22,
                height: 22,
                child: Tooltip(
                  message: pin.label,
                  child: GestureDetector(
                    onTap: pin.onTap,
                    child: Container(
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.85),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.near_me, size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ),
            if (points.isNotEmpty)
              Positioned(
                left: points.first.x * s - 9,
                top: points.first.y * s - 9,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: AppColors.ink,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                ),
              ),
            if (points.length > 1)
              Positioned(
                left: points.last.x * s - 16,
                top: points.last.y * s - 32,
                child: Icon(Icons.location_on, size: 32, color: color),
              ),
          ],
        );
      },
    );
  }
}
