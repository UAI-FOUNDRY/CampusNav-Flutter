import 'package:flutter/material.dart';
import '../data/mock_campus.dart';
import '../models/route.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import 'route_painter.dart';

/// One floor of a building. Put it inside a [MapFrame].
///
/// Pass [targetFloor], [targetRoomId] and [connectorType] to draw the indoor
/// part of a route on this floor.
class FloorPlan extends StatelessWidget {
  final List<IndoorRoom> rooms;
  final int floor;
  final int? targetFloor;
  final String? targetRoomId;
  final String? connectorType; // "stairs" or "lift"
  final Color color;
  final Set<String> tappableRoomIds;
  final ValueChanged<IndoorRoom>? onRoomTap;

  const FloorPlan({
    super.key,
    required this.rooms,
    required this.floor,
    this.targetFloor,
    this.targetRoomId,
    this.connectorType,
    this.color = AppColors.academic,
    this.tappableRoomIds = const {},
    this.onRoomTap,
  });

  /// The route on THIS floor, as points in plan units.
  List<MapPoint> _routePoints() {
    if (targetFloor == null) return const [];

    IndoorRoom? find(bool Function(IndoorRoom) test) {
      for (final r in rooms) {
        if (test(r)) return r;
      }
      return null;
    }

    MapPoint centre(IndoorRoom r) =>
        MapPoint(r.left + r.width / 2, r.top + r.height / 2);

    final target = targetRoomId == null ? null : find((r) => r.id == targetRoomId);
    final connector = connectorType == null ? null : find((r) => r.kind == connectorType);
    const y = MockCampus.corridorY;

    // Ground floor, destination also on the ground floor.
    if (floor == 0 && targetFloor == 0) {
      if (target == null) return const [];
      final t = centre(target);
      return [const MapPoint(0, y), MapPoint(t.x, y), t];
    }
    // Ground floor, heading up: entrance -> stairs or lift.
    if (floor == 0) {
      if (connector == null) return const [];
      final c = centre(connector);
      return [const MapPoint(0, y), MapPoint(c.x, y), c];
    }
    // Destination floor: stairs or lift -> room.
    if (floor == targetFloor && connector != null && target != null) {
      final c = centre(connector);
      final t = centre(target);
      return [c, MapPoint(c.x, y), MapPoint(t.x, y), t];
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final points = _routePoints();
    final onTargetFloor = targetFloor != null && floor == targetFloor && points.isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final s = constraints.maxWidth / MockCampus.indoorWidth;

        return Stack(
          children: [
            Positioned(
              left: 0,
              top: 220 * s,
              width: MockCampus.indoorWidth * s,
              height: 80 * s,
              child: const ColoredBox(color: Color(0xFFDDE5EF)),
            ),
            for (final r in rooms)
              Positioned(
                left: r.left * s,
                top: r.top * s,
                width: r.width * s,
                height: r.height * s,
                child: _RoomTile(
                  room: r,
                  color: color,
                  isTarget: r.id == targetRoomId && floor == targetFloor,
                  isConnector: connectorType != null && r.kind == connectorType,
                  onTap: onRoomTap != null && tappableRoomIds.contains(r.id)
                      ? () => onRoomTap!(r)
                      : null,
                ),
              ),
            if (points.length > 1)
              Positioned.fill(
                // The key restarts the animation whenever the floor changes.
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(floor),
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeInOut,
                  builder: (context, t, _) => CustomPaint(
                    painter: RoutePainter(
                      points: points,
                      scale: s,
                      color: color,
                      strokeWidth: 5,
                      progress: t,
                    ),
                  ),
                ),
              ),
            if (floor == 0)
              Positioned(
                left: 8,
                top: 226 * s,
                child: const Text(
                  'Entrance',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkMuted,
                  ),
                ),
              ),
            if (floor == 0 && points.isNotEmpty)
              Positioned(
                left: 2,
                top: MockCampus.corridorY * s - 9,
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
            if (onTargetFloor)
              Positioned(
                left: points.last.x * s - 14,
                top: points.last.y * s - 28,
                child: const Icon(Icons.location_on, size: 28, color: AppColors.ink),
              ),
          ],
        );
      },
    );
  }
}

class _RoomTile extends StatelessWidget {
  final IndoorRoom room;
  final Color color;
  final bool isTarget;
  final bool isConnector;
  final VoidCallback? onTap;

  const _RoomTile({
    required this.room,
    required this.color,
    required this.isTarget,
    required this.isConnector,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tappable = onTap != null;
    final isVertical = room.kind != 'room'; // stairs or lift

    var fill = Colors.white;
    var border = AppColors.mist;
    var foreground = AppColors.ink;
    if (isTarget) {
      fill = color;
      border = color;
      foreground = readableOnLine(color);
    } else if (isVertical) {
      fill = AppColors.ink.withValues(alpha: isConnector ? 0.2 : 0.07);
      border = AppColors.ink.withValues(alpha: isConnector ? 0.5 : 0.15);
    } else if (tappable) {
      fill = color.withValues(alpha: 0.1);
      border = color;
      foreground = lineInk(color);
    }

    final Widget label;
    if (room.kind == 'stairs') {
      label = Icon(Icons.stairs, color: foreground);
    } else if (room.kind == 'lift') {
      label = Icon(Icons.elevator, color: foreground);
    } else {
      label = Text(
        room.name.replaceFirst(' ', '\n'),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          height: 1.15,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      );
    }

    final radius = BorderRadius.circular(8);
    return Material(
      color: fill,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: border, width: isTarget || tappable ? 1.5 : 1),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: label)),
        ),
      ),
    );
  }
}
