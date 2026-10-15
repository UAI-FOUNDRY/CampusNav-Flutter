class Destination {
  final String id; // node/room id the backend uses, e.g. "ai_lab"
  final String name;
  final String building;
  final int floor; // 0 = ground floor
  final String type; // library, lab, hall, cafeteria, ...

  // Where it is, when the backend knows. Outdoor places have lat/lng,
  // indoor ones have x/y (pixels on the floor-plan image).
  final double? lat;
  final double? lng;
  final double? x;
  final double? y;

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
  });

  bool get hasGeo => lat != null && lng != null;
  bool get isIndoor => !hasGeo && x != null && y != null;

  factory Destination.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] ?? '').toString();
    return Destination(
      id: (json['id'] ?? '').toString(),
      name: name,
      // Outdoor entrances have no building in the data; group them as "Campus".
      building: (json['building'] ?? '').toString().trim().isEmpty
          ? 'Campus'
          : json['building'].toString(),
      // Accepts 2 or "2" so a small backend difference doesn't crash the app.
      floor: int.tryParse((json['floor'] ?? '0').toString()) ?? 0,
      type: _inferType((json['type'] ?? 'place').toString(), name),
      lat: double.tryParse((json['lat'] ?? '').toString()),
      lng: double.tryParse((json['lng'] ?? '').toString()),
      x: double.tryParse((json['x'] ?? '').toString()),
      y: double.tryParse((json['y'] ?? '').toString()),
    );
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
