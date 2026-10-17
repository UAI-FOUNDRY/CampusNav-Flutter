/// Where the user is right now: a place or a named spot on the campus graph
/// (picked from the list, scanned from a QR code), or their GPS position.
class StartPoint {
  final String id; // place id or graph node id (the backend accepts both)
  final String name;
  final String hint; // "Block A · Ground floor", "Outside" ...

  /// Kind of spot, for the icon: a place type (lab, office ...) or
  /// "stairs", "lift", "gate", "entrance".
  final String type;

  /// List section: "Outside", "Block A · Ground floor" ... Null = not listed.
  final String? group;

  final int? floor;
  final bool indoor;
  final double? lat;
  final double? lng;

  /// From the phone's GPS: routes start at [lat]/[lng] (the server snaps it
  /// to the nearest path); [id] is the nearest named spot, used for walking
  /// times and the "near ..." text.
  final bool live;
  final double? accuracy; // metres

  const StartPoint({
    required this.id,
    required this.name,
    required this.hint,
    this.type = 'place',
    this.group,
    this.floor,
    this.indoor = false,
    this.lat,
    this.lng,
    this.live = false,
    this.accuracy,
  });

  bool get hasGeo => lat != null && lng != null;

  /// Text for search: name, section and hint.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        hint.toLowerCase().contains(q) ||
        (group?.toLowerCase().contains(q) ?? false) ||
        type.toLowerCase().contains(q);
  }
}
