import 'package:flutter/material.dart';
import '../data/mock_campus.dart';
import '../models/route.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import 'route_painter.dart';

/// Schematic outdoor map. Put it inside a [MapFrame].
///
/// Layers, bottom to top: roads, route line, buildings, markers.
class CampusMap extends StatelessWidget {
  final List<MapPoint> routePath;
  final Color routeColor;
  final String? startNodeId;
  final String? highlightBuilding;
  final ValueChanged<CampusBuilding>? onBuildingTap;

  const CampusMap({
    super.key,
    this.routePath = const [],
    this.routeColor = AppColors.academic,
    this.startNodeId,
    this.highlightBuilding,
    this.onBuildingTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Everything is drawn in map units and multiplied by [s] to get pixels.
        final s = constraints.maxWidth / MockCampus.canvasWidth;
        final start = startNodeId == null ? null : MockCampus.node(startNodeId!);
        final end = routePath.isEmpty ? null : routePath.last;

        return Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _RoadsPainter(s))),
            if (routePath.length > 1)
              Positioned.fill(
                child: CustomPaint(
                  painter: RoutePainter(
                    points: routePath,
                    scale: s,
                    color: routeColor,
                    strokeWidth: 6,
                    dots: true,
                  ),
                ),
              ),
            for (final b in MockCampus.buildings)
              Positioned(
                left: b.left * s,
                top: b.top * s,
                width: b.width * s,
                height: b.height * s,
                child: _BuildingTile(
                  building: b,
                  highlighted: b.name == highlightBuilding,
                  onTap: onBuildingTap == null ? null : () => onBuildingTap!(b),
                ),
              ),
            Positioned(
              left: 500 * s - 40,
              top: 652 * s,
              width: 80,
              child: const Center(
                child: Text(
                  'Main Gate',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkMuted,
                  ),
                ),
              ),
            ),
            if (start != null)
              Positioned(
                left: start.x * s - 10,
                top: start.y * s - 10,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: AppColors.ink,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                ),
              ),
            if (end != null)
              Positioned(
                left: end.x * s - 16,
                top: end.y * s - 32,
                child: Icon(Icons.location_on, size: 32, color: routeColor),
              ),
          ],
        );
      },
    );
  }
}

class _BuildingTile extends StatelessWidget {
  final CampusBuilding building;
  final bool highlighted;
  final VoidCallback? onTap;

  const _BuildingTile({
    required this.building,
    required this.highlighted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final line = lineColorForBuilding(building.name);
    final radius = BorderRadius.circular(12);

    return Material(
      color: highlighted ? line : line.withValues(alpha: 0.14),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: line, width: 2),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Text(
              building.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: highlighted ? readableOnLine(line) : lineInk(line),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoadsPainter extends CustomPainter {
  final double scale;
  const _RoadsPainter(this.scale);

  @override
  void paint(Canvas canvas, Size size) {
    final casing = Paint()
      ..color = const Color(0xFFD5DDE8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..strokeCap = StrokeCap.round;
    final road = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;

    for (final paint in [casing, road]) {
      for (final e in MockCampus.edges) {
        final a = MockCampus.node(e[0]);
        final b = MockCampus.node(e[1]);
        canvas.drawLine(
          Offset(a.x * scale, a.y * scale),
          Offset(b.x * scale, b.y * scale),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RoadsPainter old) => old.scale != scale;
}
