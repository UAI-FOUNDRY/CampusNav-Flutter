import 'dart:math' as math;

import '../models/destination.dart';
import '../models/route.dart';
import '../models/start_point.dart';

/// A point on the campus road network (map units, not metres).
class MapNode {
  final String id;
  final String name;
  final double x;
  final double y;

  const MapNode(this.id, this.name, this.x, this.y);
}

class CampusBuilding {
  final String name;
  final double left;
  final double top;
  final double width;
  final double height;
  final String entranceNodeId;
  final int topFloor;

  const CampusBuilding({
    required this.name,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.entranceNodeId,
    required this.topFloor,
  });
}

class IndoorRoom {
  final String id;
  final String name;
  final double left;
  final double top;
  final double width;
  final double height;

  /// room | stairs | lift
  final String kind;

  const IndoorRoom(
    this.id,
    this.name,
    this.left,
    this.top,
    this.width,
    this.height, [
    this.kind = 'room',
  ]);
}

class _Segment {
  final String type;
  double meters;
  String toName;

  _Segment(this.type, this.meters, this.toName);
}

/// Demo data so the whole app works before the Flask backend exists.
///
/// The map is a schematic drawn on a 1000 x 700 canvas. When the real campus
/// GeoJSON is ready, the backend will send real coordinates instead.
class MockCampus {
  MockCampus._();

  static const double canvasWidth = 1000;
  static const double canvasHeight = 700;
  static const double indoorWidth = 1000;
  static const double indoorHeight = 520;
  static const double corridorY = 260;
  static const double metersPerUnit = 0.35;

  // ---------------------------------------------------------------- outdoors

  static const nodes = <MapNode>[
    MapNode('gate_main', 'Main Gate', 500, 640),
    MapNode('main_junction', 'Main Junction', 500, 520),
    MapNode('acad_junction', 'Academic Junction', 265, 520),
    MapNode('acad_entrance', 'Academic Building entrance', 265, 480),
    MapNode('mainb_junction', 'Main Building Junction', 690, 520),
    MapNode('main_entrance', 'Main Building entrance', 690, 480),
    MapNode('north_junction', 'North Junction', 500, 270),
    MapNode('hostel_junction', 'Hostel Junction', 725, 270),
    MapNode('hostel_entrance', 'Hostel entrance', 725, 210),
    MapNode('sports_junction', 'Sports Junction', 250, 270),
    MapNode('sports_entrance', 'Sports Building entrance', 250, 210),
  ];

  static const edges = <List<String>>[
    ['gate_main', 'main_junction'],
    ['main_junction', 'acad_junction'],
    ['acad_junction', 'acad_entrance'],
    ['main_junction', 'mainb_junction'],
    ['mainb_junction', 'main_entrance'],
    ['main_junction', 'north_junction'],
    ['north_junction', 'hostel_junction'],
    ['hostel_junction', 'hostel_entrance'],
    ['north_junction', 'sports_junction'],
    ['sports_junction', 'sports_entrance'],
  ];

  static const buildings = <CampusBuilding>[
    CampusBuilding(
      name: 'Academic Building',
      left: 150,
      top: 330,
      width: 230,
      height: 150,
      entranceNodeId: 'acad_entrance',
      topFloor: 3,
    ),
    CampusBuilding(
      name: 'Main Building',
      left: 560,
      top: 330,
      width: 260,
      height: 150,
      entranceNodeId: 'main_entrance',
      topFloor: 2,
    ),
    CampusBuilding(
      name: 'Hostel',
      left: 600,
      top: 80,
      width: 250,
      height: 130,
      entranceNodeId: 'hostel_entrance',
      topFloor: 3,
    ),
    CampusBuilding(
      name: 'Sports Building',
      left: 120,
      top: 80,
      width: 260,
      height: 130,
      entranceNodeId: 'sports_entrance',
      topFloor: 0,
    ),
  ];

  static const startPoints = <StartPoint>[
    StartPoint(id: 'gate_main', name: 'Main Gate', hint: 'Where most visitors arrive'),
    StartPoint(id: 'acad_entrance', name: 'Academic Building', hint: 'Main entrance'),
    StartPoint(id: 'main_entrance', name: 'Main Building', hint: 'Main entrance'),
    StartPoint(id: 'hostel_entrance', name: 'Hostel', hint: 'Main entrance'),
    StartPoint(id: 'sports_entrance', name: 'Sports Building', hint: 'Main entrance'),
  ];

  static const destinations = <Destination>[
    Destination(id: 'library', name: 'Library', building: 'Academic Building', floor: 1, type: 'library'),
    Destination(id: 'ai_lab', name: 'AI Lab', building: 'Academic Building', floor: 2, type: 'lab'),
    Destination(id: 'cafeteria', name: 'Cafeteria', building: 'Main Building', floor: 1, type: 'cafeteria'),
    Destination(id: 'sports_complex', name: 'Sports Complex', building: 'Sports Building', floor: 0, type: 'sports'),
    Destination(id: 'computer_lab', name: 'Computer Lab', building: 'Academic Building', floor: 3, type: 'lab'),
    Destination(id: 'seminar_hall', name: 'Seminar Hall', building: 'Academic Building', floor: 0, type: 'hall'),
    Destination(id: 'admin_office', name: 'Admin Office', building: 'Main Building', floor: 0, type: 'office'),
    Destination(id: 'auditorium', name: 'Auditorium', building: 'Main Building', floor: 0, type: 'auditorium'),
    Destination(id: 'gym', name: 'Gym', building: 'Sports Building', floor: 0, type: 'gym'),
    Destination(id: 'turf', name: 'Turf', building: 'Sports Building', floor: 0, type: 'turf'),
    Destination(id: 'hostel_reception', name: 'Hostel Reception', building: 'Hostel', floor: 0, type: 'hostel'),
  ];

  // ----------------------------------------------------------------- indoors
  // Only the Academic Building (the pilot) has floor plans so far.
  // Every floor: corridor in the middle (y 220-300), rooms above and below.

  static const floorPlans = <String, Map<int, List<IndoorRoom>>>{
    'Academic Building': {
      0: [
        IndoorRoom('seminar_hall', 'Seminar Hall', 40, 40, 380, 180),
        IndoorRoom('reception', 'Reception', 440, 40, 200, 180),
        IndoorRoom('wc_0', 'WC', 660, 40, 120, 180),
        IndoorRoom('lift', 'Lift', 800, 140, 70, 80, 'lift'),
        IndoorRoom('stairs', 'Stairs', 890, 140, 70, 80, 'stairs'),
        IndoorRoom('faculty_lounge', 'Faculty Lounge', 40, 300, 300, 180),
        IndoorRoom('waiting_area', 'Waiting Area', 360, 300, 300, 180),
        IndoorRoom('server_room', 'Server Room', 680, 300, 280, 180),
      ],
      1: [
        IndoorRoom('library', 'Library', 40, 40, 420, 180),
        IndoorRoom('reading_room', 'Reading Room', 480, 40, 300, 180),
        IndoorRoom('lift', 'Lift', 800, 140, 70, 80, 'lift'),
        IndoorRoom('stairs', 'Stairs', 890, 140, 70, 80, 'stairs'),
        IndoorRoom('faculty_room', 'Faculty Room', 40, 300, 280, 180),
        IndoorRoom('room_101', 'Room 101', 340, 300, 300, 180),
        IndoorRoom('room_102', 'Room 102', 660, 300, 300, 180),
      ],
      2: [
        IndoorRoom('ai_lab', 'AI Lab', 40, 40, 300, 180),
        IndoorRoom('data_lab', 'Data Lab', 360, 40, 240, 180),
        IndoorRoom('room_201', 'Room 201', 620, 40, 160, 180),
        IndoorRoom('lift', 'Lift', 800, 140, 70, 80, 'lift'),
        IndoorRoom('stairs', 'Stairs', 890, 140, 70, 80, 'stairs'),
        IndoorRoom('room_202', 'Room 202', 40, 300, 300, 180),
        IndoorRoom('room_203', 'Room 203', 360, 300, 300, 180),
        IndoorRoom('staff_room', 'Staff Room', 680, 300, 280, 180),
      ],
      3: [
        IndoorRoom('computer_lab', 'Computer Lab', 40, 40, 420, 180),
        IndoorRoom('room_301', 'Room 301', 480, 40, 300, 180),
        IndoorRoom('lift', 'Lift', 800, 140, 70, 80, 'lift'),
        IndoorRoom('stairs', 'Stairs', 890, 140, 70, 80, 'stairs'),
        IndoorRoom('hod_cabin', 'HOD Cabin', 40, 300, 240, 180),
        IndoorRoom('room_302', 'Room 302', 300, 300, 330, 180),
        IndoorRoom('room_303', 'Room 303', 650, 300, 310, 180),
      ],
    },
  };

  // ----------------------------------------------------------------- lookups

  static MapNode node(String id) => nodes.firstWhere((n) => n.id == id);

  static CampusBuilding? buildingNamed(String name) {
    for (final b in buildings) {
      if (b.name == name) return b;
    }
    return null;
  }

  /// Turns the text inside a QR code into a start point.
  /// Accepts "campusnav:<node id>" or just "<node id>". Returns null for
  /// codes that are not from this campus.
  static StartPoint? startPointFromCode(String raw) {
    var id = raw.trim();
    if (id.startsWith('campusnav:')) id = id.substring('campusnav:'.length);

    for (final p in startPoints) {
      if (p.id == id) return p;
    }
    for (final n in nodes) {
      if (n.id == id) return StartPoint(id: n.id, name: n.name, hint: 'From a QR code');
    }
    return null;
  }

  static List<Destination> search(String query) =>
      destinations.where((d) => d.matches(query)).toList();

  // ----------------------------------------------------------------- routing

  static Iterable<String> _neighbours(String id) sync* {
    for (final e in edges) {
      if (e[0] == id) yield e[1];
      if (e[1] == id) yield e[0];
    }
  }

  static double _distance(MapNode a, MapNode b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Dijkstra's shortest path. The real backend will use A*; on a graph this
  /// small the result is identical.
  static List<MapNode> _shortestPath(String fromId, String toId) {
    final dist = <String, double>{for (final n in nodes) n.id: double.infinity};
    final prev = <String, String?>{};
    final open = <String>{for (final n in nodes) n.id};
    dist[fromId] = 0;

    while (open.isNotEmpty) {
      String? current;
      for (final id in open) {
        if (current == null || dist[id]! < dist[current]!) current = id;
      }
      if (current == null || dist[current]! == double.infinity) break;
      open.remove(current);
      if (current == toId) break;

      for (final neighbour in _neighbours(current)) {
        final alt = dist[current]! + _distance(node(current), node(neighbour));
        if (alt < dist[neighbour]!) {
          dist[neighbour] = alt;
          prev[neighbour] = current;
        }
      }
    }

    final path = <MapNode>[];
    String? step = toId;
    while (step != null) {
      path.insert(0, node(step));
      step = prev[step];
    }
    if (path.first.id != fromId) {
      throw ArgumentError('No route between $fromId and $toId');
    }
    return path;
  }

  static String _titleFor(String type) {
    switch (type) {
      case 'turn_left':
        return 'Turn left';
      case 'turn_right':
        return 'Turn right';
      default:
        return 'Walk straight';
    }
  }

  /// Builds the same kind of response the Flask API will return.
  static NavigationRoute buildRoute({
    required String startId,
    required String destinationId,
    bool stepFree = false,
  }) {
    final destination = destinations.firstWhere(
      (d) => d.id == destinationId,
      orElse: () => throw ArgumentError('Unknown destination: $destinationId'),
    );
    final building = buildings.firstWhere(
      (b) => b.name == destination.building,
      orElse: () => throw ArgumentError('Unknown building'),
    );
    final start = node(startId);
    final path = _shortestPath(startId, building.entranceNodeId);

    // 1. Turn the node path into segments, merging consecutive straight walks.
    final segments = <_Segment>[];
    for (var i = 0; i < path.length - 1; i++) {
      final a = path[i];
      final b = path[i + 1];
      final meters = _distance(a, b) * metersPerUnit;
      var type = 'walk';
      if (i > 0) {
        final p = path[i - 1];
        final v1x = a.x - p.x;
        final v1y = a.y - p.y;
        final v2x = b.x - a.x;
        final v2y = b.y - a.y;
        // Screen y points down, so a positive angle is a right turn.
        final angle = math.atan2(v1x * v2y - v1y * v2x, v1x * v2x + v1y * v2y);
        if (angle > 0.5) {
          type = 'turn_right';
        } else if (angle < -0.5) {
          type = 'turn_left';
        }
      }
      if (type == 'walk' && segments.isNotEmpty && segments.last.type == 'walk') {
        segments.last.meters += meters;
        segments.last.toName = b.name;
      } else {
        segments.add(_Segment(type, meters, b.name));
      }
    }

    // 2. Outdoor steps.
    final steps = <RouteStep>[
      RouteStep(type: 'start', title: 'You are here', instruction: start.name, floor: 0),
    ];
    var total = 0.0;
    for (final s in segments) {
      total += s.meters;
      steps.add(RouteStep(
        type: s.type,
        title: _titleFor(s.type),
        instruction: 'Walk ${s.meters.round()} m to ${s.toName}',
        distance: s.meters,
        floor: 0,
      ));
    }

    // 3. Indoor steps.
    steps.add(RouteStep(
      type: 'enter',
      title: 'Enter ${building.name}',
      instruction: 'Head inside through the main entrance',
      distance: 12,
      floor: 0,
    ));
    total += 12;

    if (destination.floor > 0) {
      final useLift = stepFree || destination.floor >= 3;
      final climb = 8.0 + destination.floor * 6;
      steps.add(RouteStep(
        type: useLift ? 'lift' : 'stairs',
        title: useLift ? 'Take the lift' : 'Take the stairs',
        instruction: 'Go up to floor ${destination.floor}',
        distance: climb,
        floor: destination.floor,
      ));
      total += climb;
    }

    steps.add(RouteStep(
      type: 'arrive',
      title: destination.name,
      instruction: 'Your destination',
      floor: destination.floor,
    ));

    final minutes = total / 75 + (destination.floor > 0 ? 0.5 : 0);
    return NavigationRoute(
      distance: total,
      minutes: minutes,
      steps: steps,
      path: [for (final n in path) MapPoint(n.x, n.y)],
    );
  }
}
