import 'package:flutter/material.dart';

import '../models/route.dart';
import '../theme/app_colors.dart';
import '../widgets/floor_plan_viewer.dart';
import '../widgets/live_floor_plan.dart';
import '../widgets/live_route_map.dart';
import '../widgets/segment_toggle.dart';

/// One piece of a route the full-screen map can show.
class RouteMapPart {
  final String label; // "Outside", "Ground", "Floor 1"
  final RouteLeg? leg; // null = the outdoor part

  const RouteMapPart(this.label, this.leg);

  bool get isOutdoor => leg == null;

  /// The parts in the order they are walked: outside first, then each floor.
  static List<RouteMapPart> of(NavigationRoute route) => [
        if (route.outdoorPolyline.length > 1) const RouteMapPart('Outside', null),
        for (final leg in route.indoorLegs)
          RouteMapPart(leg.floor == 0 ? 'Ground' : 'Floor ${leg.floor}', leg),
      ];
}

/// The route map on the whole screen, one part at a time (Outside / Ground /
/// Floor 1 ...), with zoom buttons. Opened from the expand button on the
/// route screen's map cards.
class RouteMapScreen extends StatefulWidget {
  final NavigationRoute route;
  final String title;
  final Color color;
  final int initialPart;

  const RouteMapScreen({
    super.key,
    required this.route,
    required this.title,
    this.color = AppColors.academic,
    this.initialPart = 0,
  });

  @override
  State<RouteMapScreen> createState() => _RouteMapScreenState();
}

class _RouteMapScreenState extends State<RouteMapScreen> {
  late final List<RouteMapPart> _parts = RouteMapPart.of(widget.route);
  late int _index = widget.initialPart.clamp(0, _parts.isEmpty ? 0 : _parts.length - 1).toInt();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: AppColors.platform,
        surfaceTintColor: Colors.transparent,
      ),
      body: Column(
        children: [
          if (_parts.length > 1)
            Container(
              color: AppColors.platform,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SegmentToggle(
                labels: [for (final p in _parts) p.label],
                selected: _index,
                onChanged: (i) => setState(() => _index = i),
              ),
            ),
          Expanded(
            child: _parts.isEmpty
                ? const Center(child: Text('There is no map for this route yet.'))
                : KeyedSubtree(key: ValueKey(_index), child: _part(_parts[_index])),
          ),
        ],
      ),
    );
  }

  Widget _part(RouteMapPart part) {
    final leg = part.leg;
    if (leg == null) {
      return LiveCampusMap(
        route: widget.route.outdoorPolyline,
        color: widget.color,
        fill: true,
      );
    }
    return SafeArea(
      top: false,
      child: FloorPlanViewer(
        image: leg.image!,
        imageWidth: leg.imageWidth,
        imageHeight: leg.imageHeight,
        route: leg.points,
        color: widget.color,
        focus: routeFocus(leg.points, leg.imageWidth, leg.imageHeight),
      ),
    );
  }
}
