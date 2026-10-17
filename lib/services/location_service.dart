import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../models/start_point.dart';

/// Why "Use my location" did not work, so the sheet can offer the right fix.
enum LocateProblem { serviceOff, denied, deniedForever, timeout, offCampus, noMap, failed }

class LocateResult {
  final StartPoint? point;
  final LocateProblem? problem;
  final String message;

  const LocateResult.ok(StartPoint this.point, this.message) : problem = null;
  const LocateResult.fail(LocateProblem this.problem, this.message) : point = null;
}

/// The phone's GPS position as a start point.
///
/// The route itself starts at the exact position (the server snaps it to the
/// nearest campus path). The start point also remembers the nearest named
/// outdoor spot, for walking times and the "near ..." text.
class LocationService {
  LocationService._();

  /// Farther than this from every campus spot (plus the GPS error) counts as
  /// off campus. Matches the server's MAX_SNAP_M.
  static const offCampusMetres = 150.0;

  static Future<LocateResult> locate(List<StartPoint> spots) async {
    // Spots with a GPS position; outdoor ones first (GPS is poor indoors).
    final outdoor = [for (final s in spots) if (s.hasGeo && !s.indoor) s];
    final candidates = outdoor.isNotEmpty ? outdoor : [for (final s in spots) if (s.hasGeo) s];
    if (candidates.isEmpty) {
      return const LocateResult.fail(
        LocateProblem.noMap,
        'The campus map is not loaded yet, so your position cannot be matched to a place.',
      );
    }

    final blocked = await permissionProblem();
    if (blocked != null) return blocked;

    final Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } on TimeoutException {
      return const LocateResult.fail(
        LocateProblem.timeout,
        'No GPS fix yet. GPS is weak inside buildings: step outside, or scan the QR code on a nearby sign.',
      );
    } catch (_) {
      return const LocateResult.fail(
        LocateProblem.failed,
        'Could not read your location. Try again, or pick a place from the list.',
      );
    }

    StartPoint? nearest;
    var best = double.infinity;
    for (final s in candidates) {
      final d = Geolocator.distanceBetween(position.latitude, position.longitude, s.lat!, s.lng!);
      if (d < best) {
        best = d;
        nearest = s;
      }
    }
    final near = nearest!;
    final accuracy = position.accuracy;

    if (best > offCampusMetres + accuracy) {
      final away = best >= 1000 ? '${(best / 1000).toStringAsFixed(1)} km' : '${best.round()} m';
      return LocateResult.fail(
        LocateProblem.offCampus,
        'You seem to be off campus ($away from the nearest path). Routes start on campus: pick a place instead.',
      );
    }

    final point = StartPoint(
      id: near.id,
      name: 'My location',
      hint: 'Near ${near.name} · ±${accuracy.round()} m',
      type: 'gps',
      group: near.group,
      lat: position.latitude,
      lng: position.longitude,
      live: true,
      accuracy: accuracy,
    );
    return LocateResult.ok(point, 'Starting from your location, near ${near.name}.');
  }

  /// Location on and allowed (asks once if needed)? Null when fine,
  /// otherwise what is wrong.
  static Future<LocateResult?> permissionProblem() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return const LocateResult.fail(
        LocateProblem.serviceOff,
        'Location is turned off on this phone.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      return const LocateResult.fail(
        LocateProblem.deniedForever,
        'Location access is blocked for this app. Allow it in Settings to use your location.',
      );
    }
    if (permission == LocationPermission.denied) {
      return const LocateResult.fail(
        LocateProblem.denied,
        'Without location access the app cannot tell where you are. Pick a place or scan a QR code instead.',
      );
    }
    return null;
  }

  /// Live positions while guiding: the best accuracy, a new fix every couple
  /// of metres walked.
  static Stream<Position> follow() => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 2,
        ),
      );

  static Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  static Future<void> openAppSettings() => Geolocator.openAppSettings();
}
