double? _asDouble(dynamic value) =>
    value == null ? null : double.tryParse(value.toString());

int? _asInt(dynamic value) =>
    value == null ? null : int.tryParse(value.toString());

/// A point on the demo (schematic) map, in map units (x right, y down).
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

/// A real-world coordinate from the backend (`[lat, lng]`).
/// Kept free of map packages so the models stay plain Dart.
class GeoPoint {
  final double lat;
  final double lng;

  const GeoPoint(this.lat, this.lng);

  static GeoPoint? tryParse(dynamic json) {
    if (json is List && json.length >= 2) {
      final lat = _asDouble(json[0]);
      final lng = _asDouble(json[1]);
      if (lat != null && lng != null) return GeoPoint(lat, lng);
    }
    return null;
  }
}

/// A node on a floor-plan image, in IMAGE PIXELS (not screen pixels).
class IndoorPoint {
  final String id;
  final String name;
  final double x;
  final double y;

  const IndoorPoint({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
  });
}

/// One piece of a live route: either outside (drawn on the map) or inside
/// (drawn on a floor-plan image). A gate-to-classroom route is outdoor + indoor.
class RouteLeg {
  final bool isIndoor;
  final double distance; // metres

  // Outdoor legs
  final List<GeoPoint> polyline;

  // Indoor legs
  final int floor;
  final String? image; // file name, e.g. "ground.png"
  final double imageWidth; // pixels
  final double imageHeight;
  final List<IndoorPoint> points;

  const RouteLeg({
    required this.isIndoor,
    required this.distance,
    this.polyline = const [],
    this.floor = 0,
    this.image,
    this.imageWidth = 0,
    this.imageHeight = 0,
    this.points = const [],
  });

  factory RouteLeg.fromBackend(Map<String, dynamic> json) {
    final indoor = json['type'] == 'indoor';
    final size = json['image_size'] as List?;
    return RouteLeg(
      isIndoor: indoor,
      distance: _asDouble(json['distance_m']) ?? 0,
      polyline: [
        for (final p in (json['polyline'] as List? ?? const []))
          if (GeoPoint.tryParse(p) != null) GeoPoint.tryParse(p)!,
      ],
      floor: _asInt(json['floor']) ?? 0,
      image: json['image']?.toString(),
      imageWidth: size != null && size.length >= 2 ? _asDouble(size[0]) ?? 0 : 0,
      imageHeight: size != null && size.length >= 2 ? _asDouble(size[1]) ?? 0 : 0,
      points: [
        for (final p in (json['points'] as List? ?? const []))
          IndoorPoint(
            id: (p['id'] ?? '').toString(),
            name: (p['name'] ?? '').toString(),
            x: _asDouble(p['x']) ?? 0,
            y: _asDouble(p['y']) ?? 0,
          ),
      ],
    );
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

  /// Turns one step of the Flask `/api/route` answer into the step the UI
  /// draws. The backend only sends a sentence ("Turn right at the junction and
  /// walk 60 m"), so the icon type and a short title are read from it.
  factory RouteStep.fromBackend(Map<String, dynamic> json) {
    var text = (json['instruction'] ?? '').toString();
    var type = 'walk';
    var title = 'Walk straight';

    final turn = RegExp(r'^(Turn|Bear|Make a sharp) (left|right)', caseSensitive: false)
        .firstMatch(text);
    if (turn != null) {
      type = turn.group(2)!.toLowerCase() == 'left' ? 'turn_left' : 'turn_right';
      title = turn.group(0)!;
    } else if (text.startsWith('Go inside')) {
      type = 'enter';
      title = 'Go inside';
    } else if (text.startsWith('Go outside')) {
      title = 'Go outside';
    }

    // "Start at Main Gate and walk 125 m" -> "Walk 125 m"
    // (the "You are here" step already says where you start).
    final lead = RegExp(r'^(?:Start at|Continue from) .+? and (walk \d+ m)$',
            caseSensitive: false)
        .firstMatch(text);
    if (lead != null) {
      final walk = lead.group(1)!;
      text = '${walk[0].toUpperCase()}${walk.substring(1)}';
    }

    return RouteStep(
      type: type,
      title: title,
      instruction: text,
      distance: _asDouble(json['distance_m']),
      floor: _asInt(json['floor']) ?? 0,
    );
  }
}

class NavigationRoute {
  final double distance; // metres
  final double minutes;
  final List<RouteStep> steps;
  final List<MapPoint> path; // demo-map path (empty for live routes)
  final List<RouteLeg> legs; // live routes: what to draw, in order

  const NavigationRoute({
    required this.distance,
    required this.minutes,
    required this.steps,
    this.path = const [],
    this.legs = const [],
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

  /// Every outdoor leg joined into one line for the map.
  List<GeoPoint> get outdoorPolyline => [
        for (final leg in legs)
          if (!leg.isIndoor) ...leg.polyline,
      ];

  /// Indoor legs that have a floor-plan image to draw on.
  List<RouteLeg> get indoorLegs => [
        for (final leg in legs)
          if (leg.isIndoor && leg.image != null && leg.imageWidth > 0 && leg.imageHeight > 0)
            leg,
      ];

  /// Demo-format answer (the old POST /api/route contract).
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

  /// The Flask answer of GET /api/route (see docs/api.md in the backend repo).
  factory NavigationRoute.fromBackend(
    Map<String, dynamic> json, {
    String startName = 'Your location',
  }) {
    final raw = (json['steps'] as List? ?? const [])
        .map((s) => Map<String, dynamic>.from(s as Map))
        .toList();

    final steps = <RouteStep>[
      RouteStep(type: 'start', title: 'You are here', instruction: startName, floor: 0),
    ];
    for (var i = 0; i < raw.length - 1; i++) {
      steps.add(RouteStep.fromBackend(raw[i]));
    }
    // The backend's last step is "Arrive at <place>".
    steps.add(RouteStep(
      type: 'arrive',
      title: (json['to_name'] ?? 'Destination').toString(),
      instruction: 'Your destination',
      floor: raw.isEmpty ? 0 : _asInt(raw.last['floor']) ?? 0,
    ));

    return NavigationRoute(
      distance: _asDouble(json['distance_m']) ?? 0,
      minutes: (_asDouble(json['duration_s']) ?? 0) / 60,
      steps: steps,
      legs: [
        for (final leg in (json['legs'] as List? ?? const []))
          RouteLeg.fromBackend(Map<String, dynamic>.from(leg as Map)),
      ],
    );
  }
}
