/// One floor-plan picture the backend knows about (GET /api/floors or the
/// "floors" list inside GET /api/graph).
class FloorInfo {
  final int floor; // 0 = ground
  final String label; // "Ground floor", "First floor" ...
  final String image; // file name in assets/floorplans/, e.g. "first.png"
  final double imageWidth; // pixels the x/y values refer to
  final double imageHeight;

  const FloorInfo({
    required this.floor,
    required this.label,
    required this.image,
    required this.imageWidth,
    required this.imageHeight,
  });

  static FloorInfo? tryParse(dynamic json) {
    if (json is! Map) return null;
    final size = json['image_size'];
    final floor = int.tryParse('${json['floor']}');
    final image = json['image']?.toString();
    if (floor == null || image == null || size is! List || size.length < 2) return null;
    final w = double.tryParse('${size[0]}') ?? 0;
    final h = double.tryParse('${size[1]}') ?? 0;
    if (w <= 0 || h <= 0) return null;
    final label = json['label']?.toString();
    return FloorInfo(
      floor: floor,
      label: (label == null || label.isEmpty)
          ? (floor == 0 ? 'Ground floor' : 'Floor $floor')
          : label,
      image: image,
      imageWidth: w,
      imageHeight: h,
    );
  }

  /// The three floors of the main building, used if an older backend does
  /// not send its floor list. Sizes match the bundled pictures.
  static const fallback = <FloorInfo>[
    FloorInfo(floor: 0, label: 'Ground floor', image: 'ground.png', imageWidth: 1357, imageHeight: 882),
    FloorInfo(floor: 1, label: 'First floor', image: 'first.png', imageWidth: 1358, imageHeight: 874),
    FloorInfo(floor: 2, label: 'Second floor', image: 'second.png', imageWidth: 1358, imageHeight: 919),
  ];
}
