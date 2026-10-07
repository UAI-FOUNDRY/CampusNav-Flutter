/// Where the user is right now.
/// Later, scanning a QR code will produce one of these from the node id
/// printed in the code.
class StartPoint {
  final String id; // graph node id
  final String name;
  final String hint;

  const StartPoint({
    required this.id,
    required this.name,
    required this.hint,
  });
}
