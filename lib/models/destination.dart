class Destination {
  final String id; // node/room id the backend uses, e.g. "ai_lab"
  final String name;
  final String building;
  final int floor; // 0 = ground floor
  final String type; // library, lab, hall, cafeteria, ...

  // Where it is, when the backend knows. Outdoor places have lat/lng.
  // Indoor places have x/y (pixels on the floor-plan image) and, since
  // backend update 7, also an approximate lat/lng.
  final double? lat;
  final double? lng;
  final double? x;
  final double? y;

  /// What the backend says ("indoor": true). Null on older backends.
  final bool? indoor;

  /// "Library" for a lab that sits inside the Library. Null otherwise.
  final String? withinName;

  const Destination({
    required this.id,
    required this.name,
    required this.building,
    required this.floor,
    required this.type,
    this.lat,
    this.lng,
    this.x,
    this.y,
    this.indoor,
    this.withinName,
  });

  bool get hasGeo => lat != null && lng != null;

  /// Drawn on a floor plan (needs x/y). Older backends sent no "indoor" flag
  /// and no lat/lng for indoor places, so fall back to that rule.
  bool get isIndoor => x != null && y != null && (indoor ?? !hasGeo);

  /// "Block A, Ground floor" or "Inside the Library, Block A, Floor 1".
  String get locationLine {
    final where = '$building, ${floor == 0 ? 'Ground floor' : 'Floor $floor'}';
    final inside = withinName;
    return (inside == null || inside.isEmpty) ? where : 'Inside the $inside · $where';
  }

  factory Destination.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] ?? '').toString();
    final within = json['within_name']?.toString();
    return Destination(
      id: (json['id'] ?? '').toString(),
      name: name,
      // Outdoor entrances have no building in the data; group them as "Campus".
      building: (json['building'] ?? '').toString().trim().isEmpty
          ? 'Campus'
          : json['building'].toString(),
      // Accepts 2 or "2" so a small backend difference doesn't crash the app.
      floor: int.tryParse((json['floor'] ?? '0').toString()) ?? 0,
      type: _typeFor(json['category'], (json['type'] ?? 'place').toString(), name),
      lat: double.tryParse((json['lat'] ?? '').toString()),
      lng: double.tryParse((json['lng'] ?? '').toString()),
      x: double.tryParse((json['x'] ?? '').toString()),
      y: double.tryParse((json['y'] ?? '').toString()),
      indoor: json['indoor'] is bool ? json['indoor'] as bool : null,
      withinName: (within == null || within.isEmpty) ? null : within,
    );
  }

  /// A place from GET /api/graph: the room plus the nodes it points to
  /// ([nodes] is id -> node). Position comes from the first entry node.
  static Destination? fromGraph(Map room, Map<String, Map> nodes) {
    final ids = room['node_ids'] is List
        ? [for (final n in room['node_ids'] as List) n.toString()]
        : [if (room['node_id'] != null) room['node_id'].toString()];
    final entry = [for (final id in ids) if (nodes[id] != null) nodes[id]!];
    if (entry.isEmpty) return null;
    final first = entry.first;
    Map? geo;
    for (final n in entry) {
      if (n['lat'] != null && n['lng'] != null) {
        geo = n;
        break;
      }
    }
    final within = room['within_name']?.toString();
    return Destination.fromJson({
      'id': room['id'],
      'name': room['name'],
      'building': room['building'],
      'floor': room['floor'] ?? first['floor'],
      'type': room['type'],
      'category': room['category'],
      'lat': geo?['lat'],
      'lng': geo?['lng'],
      'x': first['x'],
      'y': first['y'],
      'indoor': entry.every((n) => n['space'] == 'indoor'),
      'within_name': ?within,
    });
  }

  /// The backend's "category" (data/places.json) wins over a guess from the name.
  static String _typeFor(dynamic category, String type, String name) {
    const fromCategory = {
      'classroom': 'hall',
      'food': 'cafeteria',
      'office': 'office',
      'lab': 'lab',
      'library': 'library',
      'sports': 'sports',
      'hostel': 'hostel',
      'auditorium': 'auditorium',
      'facility': 'facility',
      'shop': 'shop',
      'washroom': 'washroom',
    };
    final mapped = fromCategory[category?.toString()];
    return mapped ?? _inferType(type, name);
  }

  /// The campus data only says "place" or "entrance". Guess a friendlier type
  /// from the name so the search chips and icons work. Fix properly by adding
  /// a real type to data/places_v1.json when you have time.
  static String _inferType(String type, String name) {
    const generic = {'place', 'entrance', 'gate', 'door', 'room_door'};
    if (!generic.contains(type)) return type;

    final n = name.toLowerCase();
    bool has(List<String> words) => words.any(n.contains);

    if (has(['library'])) return 'library';
    if (has(['lab'])) return 'lab';
    if (has(['cafe', 'mess', 'canteen', 'bistro', 'tuck', 'vending'])) return 'cafeteria';
    if (has(['gym'])) return 'gym';
    if (has(['turf', 'sports'])) return 'sports';
    if (has(['admin', 'office', 'lobby'])) return 'office';
    if (has(['hostel'])) return 'hostel';
    if (has(['mount ', 'class', 'hall', 'design'])) return 'hall';
    return type;
  }

  /// True if the destination matches what the user typed.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final floorText = floor == 0 ? 'ground floor' : 'floor $floor';
    return name.toLowerCase().contains(q) ||
        building.toLowerCase().contains(q) ||
        type.toLowerCase().contains(q) ||
        floorText.contains(q);
  }
}
