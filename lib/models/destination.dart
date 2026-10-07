class Destination {
  final String id; // node/room id the backend uses, e.g. "ai_lab"
  final String name;
  final String building;
  final int floor; // 0 = ground floor
  final String type; // library, lab, hall, cafeteria, ...

  const Destination({
    required this.id,
    required this.name,
    required this.building,
    required this.floor,
    required this.type,
  });

  factory Destination.fromJson(Map<String, dynamic> json) {
    return Destination(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      building: (json['building'] ?? '').toString(),
      // Accepts 2 or "2" so a small backend difference doesn't crash the app.
      floor: int.tryParse((json['floor'] ?? '0').toString()) ?? 0,
      type: (json['type'] ?? 'place').toString(),
    );
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
