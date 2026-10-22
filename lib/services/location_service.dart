import 'package:flutter/foundation.dart';
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

/// Location permission and the GPS streams. "Use my location" itself is
/// [SpotLocator] (spot_locator.dart): GPS, barometer and Wi-Fi together.
class LocationService {
  LocationService._();

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

  /// Live positions while guiding: the best accuracy, one fix a second
  /// (with speed and direction), also while standing still.
  static Stream<Position> follow() =>
      Geolocator.getPositionStream(locationSettings: settings());

  /// Settings for a stream of precise fixes every [interval].
  static LocationSettings settings({Duration interval = const Duration(seconds: 1)}) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: interval,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.fitness, // walking: no snapping to roads
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: false,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.bestForNavigation);
  }

  static Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  static Future<void> openAppSettings() => Geolocator.openAppSettings();
}
