double? _asDouble(dynamic value) =>
    value == null ? null : double.tryParse(value.toString());

int? _asInt(dynamic value) =>
    value == null ? null : int.tryParse(value.toString());

/// A point on the map, in map units (x right, y down).
class MapPoint {
  final double x;
  final double y;

  const MapPoint(this.x, this.y);

  /// Accepts [x, y] or {"x": .., "y": ..}.
  factory MapPoint.fromJson(dynamic json) {
    if (json is List && json.length >= 2) {
      return MapPoint(_asDouble(json[0]) ?? 0, _asDouble(json[1]) ?? 0);
    }
    final map = Map<String, dynamic>.from(json as Map);
    return MapPoint(_asDouble(map['x']) ?? 0, _asDouble(map['y']) ?? 0);
  }
}

class RouteStep {
  /// start | walk | turn_left | turn_right | enter | stairs | lift | arrive
  final String type;
  final String title;
  final String instruction;
  final double? distance; // metres
  final int? floor;

  const RouteStep({
    required this.type,
    required this.title,
    required this.instruction,
    this.distance,
    this.floor,
  });

  bool get isFloorChange => type == 'stairs' || type == 'lift';

  factory RouteStep.fromJson(Map<String, dynamic> json) {
    final instruction = (json['instruction'] ?? '').toString();
    return RouteStep(
      type: (json['type'] ?? 'walk').toString(),
      // The backend may only send "instruction"; use it as the title then.
      title: (json['title'] ?? instruction).toString(),
      instruction: instruction,
      distance: _asDouble(json['distance']),
      floor: _asInt(json['floor']),
    );
  }
}

class NavigationRoute {
  final double distance; // metres
  final double minutes;
  final List<RouteStep> steps;
  final List<MapPoint> path; // outdoor path for the map (may be empty)

  const NavigationRoute({
    required this.distance,
    required this.minutes,
    required this.steps,
    this.path = const [],
  });

  /// The floor of the last step that has one.
  int? get targetFloor {
    for (final step in steps.reversed) {
      if (step.floor != null) return step.floor;
    }
    return null;
  }

  /// "stairs" or "lift" if the route changes floors, otherwise null.
  String? get connectorType {
    for (final step in steps) {
      if (step.isFloorChange) return step.type;
    }
    return null;
  }

  factory NavigationRoute.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'] as List? ?? const [];
    final rawPath = json['path'] as List? ?? const [];
    return NavigationRoute(
      // Accepts both "distance_meters" and "distance", and likewise for time.
      distance: _asDouble(json['distance_meters'] ?? json['distance']) ?? 0,
      minutes: _asDouble(json['estimated_minutes'] ?? json['duration']) ?? 0,
      steps: rawSteps
          .map((s) => RouteStep.fromJson(Map<String, dynamic>.from(s as Map)))
          .toList(),
      path: rawPath.map(MapPoint.fromJson).toList(),
    );
  }
}
