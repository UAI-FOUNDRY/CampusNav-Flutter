import '../models/start_point.dart';
import '../services/api_service.dart';

/// Start points for the real campus (USE_MOCK=false).
///
/// Every id here must be a node id from the backend's campus.merged.json,
/// because the app sends it as `from=<id>`. These are also the ids printed in
/// the QR codes (see tools/generate_qr.py in the backend repo).
class LiveCampus {
  LiveCampus._();

  static const startPoints = <StartPoint>[
    StartPoint(id: 'gate_main', name: 'Main Gate', hint: 'Where most visitors arrive'),
    StartPoint(id: 'quad_south_entrance', name: 'Quadrangle South Entrance', hint: 'Outside, by the quad'),
    StartPoint(id: 'a0_adminlobby', name: 'Admin Lobby', hint: 'Inside, ground floor'),
    StartPoint(id: 'mess_entrance', name: 'Mess Back Entrance', hint: 'Outside, by the mess'),
    StartPoint(id: 'turf_entrance', name: 'Turf', hint: 'Sports side of the campus'),
  ];

  /// Turns the text inside a QR code into a start point.
  /// Accepts `campusnav:<node id>` or just `<node id>`.
  ///
  /// The app cannot check the id offline, so any well-formed id is accepted;
  /// the backend answers 404 "unknown start" if it is not on the map.
  static StartPoint? startPointFromCode(String raw) {
    var id = raw.trim();
    if (id.startsWith('campusnav:')) id = id.substring('campusnav:'.length);
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(id)) return null;

    for (final p in startPoints) {
      if (p.id == id) return p;
    }
    // Any place or named spot: use its real name from the campus map.
    for (final p in ApiService.cachedCatalog?.starts ?? const <StartPoint>[]) {
      if (p.id == id) return p;
    }
    return StartPoint(id: id, name: _pretty(id), hint: 'From a QR code');
  }

  /// "mount_k2_entrance" -> "Mount K2 Entrance"
  static String _pretty(String id) => id
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
