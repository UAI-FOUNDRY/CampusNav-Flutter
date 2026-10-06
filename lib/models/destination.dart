class Destination {
  final String id;
  final String name;
  final String building;
  final int floor;
  final String type;

  const Destination({
    required this.id,
    required this.name,
    required this.building,
    required this.floor,
    required this.type,
  });

  factory Destination.fromJson(Map<String, dynamic> json) {
    return Destination(
      id: json['id'].toString(),
      name: json['name'] ?? '',
      building: json['building'] ?? '',
      floor: json['floor'] ?? 0,
      type: json['type'] ?? '',
    );
  }
}