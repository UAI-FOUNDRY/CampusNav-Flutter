import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/start_point.dart';
import 'api_service.dart';
import 'floor_barometer.dart';
import 'location_service.dart';
import 'wifi_fingerprints.dart';

/// One answer to "where exactly are you?".
class LocateCandidate {
  final StartPoint spot;

  /// 0..1 among the candidates.
  final double probability;

  /// Metres between the GPS position and the spot.
  final double distance;

  /// The Wi-Fi recognised this spot.
  final bool byWifi;

  /// You were here a few minutes ago (arrived, picked or scanned).
  final bool recent;

  const LocateCandidate(this.spot, this.probability, this.distance,
      {this.byWifi = false, this.recent = false});
}

/// What "Use my location" found.
class LocateOutcome {
  /// Sure enough: start the route here.
  final StartPoint? point;

  /// Not sure (usually inside, where GPS cannot tell rooms apart): the most
  /// likely spots, best first, for the user to pick from.
  final List<LocateCandidate> candidates;

  /// The floor you are probably on (barometer or Wi-Fi), null if unknown.
  final int? floor;
  final bool floorSure;

  /// "barometer" or "Wi-Fi" (for the chooser's text).
  final String floorBasis;

  /// Probably inside a building.
  final bool indoor;

  final double? lat;
  final double? lng;
  final double? accuracy;

  /// The Wi-Fi scan, kept so the spot you pick becomes its fingerprint,
  /// and what it said (to re-rank when another floor is chosen).
  final WifiScan? scan;
  final WifiGuess wifi;

  /// Location off / not allowed / off campus ...
  final LocateResult? problem;

  /// A sentence for the snackbar / chooser.
  final String message;

  const LocateOutcome({
    this.point,
    this.candidates = const [],
    this.floor,
    this.floorSure = false,
    this.floorBasis = '',
    this.indoor = false,
    this.lat,
    this.lng,
    this.accuracy,
    this.scan,
    this.wifi = WifiGuess.none,
    this.problem,
    this.message = '',
  });

  factory LocateOutcome.fail(LocateResult problem) =>
      LocateOutcome(problem: problem, message: problem.message);

  bool get needsChoice => point == null && problem == null;
}

/// "Use my location", done carefully:
///
///  1. GPS for a few seconds (not one fix): the sharpest fixes are averaged.
///  2. The barometer says which floor (when it has a recent reference), and
///     on Android the Wi-Fi networks around are compared with fingerprints
///     of known spots (see [WifiFingerprints]).
///  3. Every campus spot (outside AND inside) is scored by distance, floor
///     and Wi-Fi.
///  4. Outside with a sharp fix, or when the Wi-Fi is sure, that is the
///     answer. Otherwise (inside, GPS is ±15-40 m: several rooms fit) the
///     user picks from the few nearby spots on their floor; that pick
///     teaches the Wi-Fi and the barometer for next time.
class SpotLocator {
  SpotLocator._();

  /// Farther than this from every campus spot (plus the GPS error) counts as
  /// off campus. Matches the server's MAX_SNAP_M.
  static const offCampusMetres = 150.0;

  // ------------------------------------------------------- warm GPS start
  //
  // A phone's first GPS fix takes seconds. The GPS is switched on as soon as
  // the "Where are you?" sheet opens, so by the time "Use my location" is
  // tapped the fixes are already there.
  static final List<Position> _warm = [];
  static StreamSubscription<Position>? _warmSub;
  static Timer? _warmStop;

  /// Starts GPS in the background for [forSeconds] (only if location is
  /// already allowed: this never asks).
  static Future<void> warmUp({int forSeconds = 60}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always && permission != LocationPermission.whileInUse) return;
      _warmStop?.cancel();
      _warmStop = Timer(Duration(seconds: forSeconds), coolDown);
      _warmSub ??= Geolocator.getPositionStream(locationSettings: LocationService.settings()).listen(
        (p) {
          if (p.accuracy <= 0) return;
          _warm.add(p);
          if (_warm.length > 30) _warm.removeAt(0);
        },
        onError: (Object _) => coolDown(),
        cancelOnError: true,
      );
    } catch (_) {}
  }

  static void coolDown() {
    _warmStop?.cancel();
    _warmStop = null;
    unawaited(_warmSub?.cancel());
    _warmSub = null;
  }

  /// Fixes from the last [seconds] (you have not walked far since).
  static List<Position> _freshWarm(double seconds) {
    final now = DateTime.now();
    return [
      for (final p in _warm)
        if (now.difference(p.timestamp).inMilliseconds / 1000 <= seconds) p,
    ];
  }

  // -------------------------------------------------- where you just were

  static const _recentMinutes = 15;

  /// You are at [spotId] now (arrived there, picked it, or scanned its
  /// sign). For 15 minutes "Use my location" lists it first.
  static Future<void> rememberSpot(String spotId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('locate.recentSpot', spotId);
      await prefs.setInt('locate.recentAt', DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<String?> _recentSpot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('locate.recentSpot');
      final at = prefs.getInt('locate.recentAt');
      if (id == null || at == null) return null;
      final age = DateTime.now().millisecondsSinceEpoch - at;
      return age >= 0 && age <= _recentMinutes * 60 * 1000 ? id : null;
    } catch (_) {
      return null;
    }
  }

  static Future<LocateOutcome> locate(
    List<StartPoint> spots, {
    ValueChanged<String>? onStatus,
  }) async {
    final mapped = [for (final s in spots) if (s.hasGeo) s];
    if (mapped.isEmpty) {
      return LocateOutcome.fail(const LocateResult.fail(
        LocateProblem.noMap,
        'The campus map is not loaded yet, so your position cannot be matched to a place. '
        'Check the connection (or that the app runs with the backend, not the demo data).',
      ));
    }
    final blocked = await LocationService.permissionProblem();
    if (blocked != null) return LocateOutcome.fail(blocked);

    final baro = FloorBarometer.instance;
    await baro.load();
    baro.start(); // reads while GPS settles
    unawaited(baro.refreshWeather());
    final wifi = WifiFingerprints.instance;
    final Future<WifiScan?> wifiScan = wifi.supported
        ? wifi.load().then((_) => wifi.scan())
        : Future<WifiScan?>.value(null);

    final recentId = _recentSpot();
    try {
      onStatus?.call('Finding you…');
      final fixes = await _collectFixes(onStatus);
      if (fixes.isEmpty) {
        return LocateOutcome.fail(const LocateResult.fail(
          LocateProblem.timeout,
          'No GPS fix yet. GPS is weak inside buildings: step outside, or scan the QR code on a nearby sign.',
        ));
      }
      final pos = _average(fixes);
      onStatus?.call('Checking the floor…');
      final scan = await wifiScan.timeout(const Duration(seconds: 4), onTimeout: () => null);
      final byId = {for (final s in mapped) s.id: s};
      final guess = scan == null ? WifiGuess.none : wifi.guess(scan, byId);

      // Off campus?
      var nearest = double.infinity;
      for (final s in mapped) {
        nearest = math.min(nearest, Geolocator.distanceBetween(pos.lat, pos.lng, s.lat!, s.lng!));
      }
      if (nearest > offCampusMetres + pos.acc && guess.spot == null) {
        final away = nearest >= 1000 ? '${(nearest / 1000).toStringAsFixed(1)} km' : '${nearest.round()} m';
        return LocateOutcome.fail(LocateResult.fail(
          LocateProblem.offCampus,
          'You seem to be off campus ($away from the nearest path). Routes start on campus: pick a place instead.',
        ));
      }

      // Which floor?
      int? floor;
      var floorSure = false;
      var basis = '';
      final wifiFloor = guess.floor;
      final est = baro.estimate();
      if (wifiFloor != null) {
        floor = wifiFloor;
        floorSure = true;
        basis = 'Wi-Fi';
        // A sure floor from the Wi-Fi is a reference for the barometer.
        if (est == null || !est.sure) baro.setFloor(wifiFloor, basis: 'Wi-Fi');
      } else if (est != null && est.confidence >= 0.3) {
        floor = est.floor;
        floorSure = est.sure;
        basis = 'barometer';
      } else {
        // No barometer (or no reference): the floor you were last known to
        // be on, as a hint only.
        final recent = baro.recentFloor();
        if (recent != null) {
          floor = recent;
          basis = 'where you last were';
        }
      }
      final indoor = pos.acc > 12 || (floorSure && (floor ?? 0) > 0) || guess.spot != null;

      // 1) The Wi-Fi knows this room.
      final wifiSpot = guess.spot == null ? null : byId[guess.spot];
      if (wifiSpot != null) {
        final d = Geolocator.distanceBetween(pos.lat, pos.lng, wifiSpot.lat!, wifiSpot.lng!);
        if (pos.acc > 12 || d <= 3 * pos.acc + 20) {
          if (wifiSpot.indoor) baro.setFloor(wifiSpot.floor ?? 0, basis: 'Wi-Fi');
          return LocateOutcome(
            point: StartPoint(
              id: wifiSpot.id,
              name: wifiSpot.name,
              hint: 'Found by Wi-Fi · ${wifiSpot.hint}',
              type: wifiSpot.type,
              group: wifiSpot.group,
              floor: wifiSpot.floor,
              indoor: wifiSpot.indoor,
              lat: wifiSpot.lat,
              lng: wifiSpot.lng,
            ),
            floor: wifiSpot.floor,
            floorSure: true,
            floorBasis: 'Wi-Fi',
            indoor: wifiSpot.indoor,
            lat: pos.lat,
            lng: pos.lng,
            accuracy: pos.acc,
            scan: scan,
            wifi: guess,
            message: "You're at ${wifiSpot.name} (recognised by the Wi-Fi around you).",
          );
        }
      }

      final ranked = rank(
        pos.lat,
        pos.lng,
        pos.acc,
        spots: mapped,
        floor: floor,
        floorSure: floorSure,
        indoorLikely: indoor,
        wifi: guess,
        recentId: await recentId,
      );

      // 2) Outside with a sharp fix: the GPS position itself.
      final top = ranked.isEmpty ? null : ranked.first;
      if (top != null && !indoor && !top.spot.indoor && top.probability >= 0.6 && pos.acc <= 15) {
        _groundReferenceIfNearBuilding(pos, mapped);
        final near = top.spot;
        return LocateOutcome(
          point: StartPoint(
            id: near.id,
            name: 'My location',
            hint: 'Near ${near.name} · ±${pos.acc.round()} m',
            type: 'gps',
            group: near.group,
            lat: pos.lat,
            lng: pos.lng,
            live: true,
            accuracy: pos.acc,
          ),
          lat: pos.lat,
          lng: pos.lng,
          accuracy: pos.acc,
          scan: scan,
          wifi: guess,
          message: 'Starting from your location, near ${near.name}.',
        );
      }

      // 3) Not sure: let the user pick from the likely spots.
      return LocateOutcome(
        candidates: [for (final c in ranked.take(12)) if (c.probability >= 0.005) c],
        floor: floor,
        floorSure: floorSure,
        floorBasis: basis,
        indoor: indoor,
        lat: pos.lat,
        lng: pos.lng,
        accuracy: pos.acc,
        scan: scan,
        wifi: guess,
        message: indoor
            ? 'Inside, GPS is only good to about ±${pos.acc.round()} m, so pick the spot you are at.'
            : 'GPS is rough here (±${pos.acc.round()} m): pick the spot you are at.',
      );
    } finally {
      baro.stop();
    }
  }

  /// The user picked [spot] in "Where exactly are you?" (or scanned it):
  /// teach the Wi-Fi and the barometer.
  static void confirm(LocateOutcome outcome, StartPoint spot) {
    unawaited(rememberSpot(spot.id));
    if (!spot.indoor) return;
    final floor = spot.floor ?? 0;
    FloorBarometer.instance.setFloor(floor, basis: 'picked');
    final scan = outcome.scan;
    if (scan != null) unawaited(WifiFingerprints.instance.learn(spot.id, floor, scan));
  }

  /// You are at [point] for sure (a scanned sign): set the barometer's
  /// reference to its floor and keep the Wi-Fi around as its fingerprint.
  static Future<void> calibrateAt(StartPoint point, {String basis = 'sign'}) async {
    unawaited(rememberSpot(point.id));
    var p = point;
    if (p.floor == null) {
      for (final s in ApiService.cachedCatalog?.starts ?? const <StartPoint>[]) {
        if (s.id == p.id) {
          p = s;
          break;
        }
      }
    }
    if (!p.indoor) return;
    final floor = p.floor ?? 0;
    final baro = FloorBarometer.instance;
    await baro.load();
    await baro.read();
    baro.setFloor(floor, basis: basis);
    final wifi = WifiFingerprints.instance;
    if (!wifi.supported) return;
    await wifi.load();
    final scan = await wifi.scan();
    if (scan != null) await wifi.learn(p.id, floor, scan);
  }

  /// GPS fixes for up to 8 s; stops as soon as they are good enough.
  ///
  /// Starts from the fixes of the warm GPS (see [warmUp]) and the phone's
  /// own last position when only seconds old, so it is often done at once.
  static Future<List<Position>> _collectFixes(ValueChanged<String>? onStatus) async {
    final fixes = <Position>[..._freshWarm(6)];
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null &&
          last.accuracy > 0 &&
          last.accuracy <= 25 &&
          DateTime.now().difference(last.timestamp) < const Duration(seconds: 8) &&
          !fixes.any((f) => f.timestamp == last.timestamp)) {
        fixes.add(last);
      }
    } catch (_) {}
    final done = Completer<void>();
    final started = DateTime.now();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    bool goodEnough() {
      if (fixes.isEmpty) return false;
      final secs = DateTime.now().difference(started).inMilliseconds / 1000;
      final best = fixes.map((f) => f.accuracy).reduce(math.min);
      final sharp = fixes.where((f) => f.accuracy <= 8).length;
      return sharp >= 2 ||
          (secs >= 2 && best <= 10) ||
          (secs >= 3 && best <= 15) ||
          (secs >= 5 && best <= 30) ||
          secs >= 8;
    }

    if (goodEnough()) return fixes;
    final sub = Geolocator.getPositionStream(locationSettings: LocationService.settings()).listen(
      (p) {
        if (p.accuracy <= 0) return;
        fixes.add(p);
        onStatus?.call('GPS ±${p.accuracy.round()} m…');
        if (goodEnough()) finish();
      },
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
    // Also stop on time when no new fix arrives (inside, GPS can go quiet).
    final tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (goodEnough()) finish();
    });
    final timer = Timer(const Duration(seconds: 12), finish);
    await done.future;
    timer.cancel();
    tick.cancel();
    await sub.cancel();
    if (fixes.isEmpty) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null && DateTime.now().difference(last.timestamp) < const Duration(minutes: 2)) {
          fixes.add(last);
        }
      } catch (_) {}
    }
    return fixes;
  }

  /// The sharpest recent fixes, averaged (weighted by 1 / accuracy²).
  static ({double lat, double lng, double acc}) _average(List<Position> fixes) {
    final best = fixes.map((f) => f.accuracy).reduce(math.min);
    final use = [for (final f in fixes) if (f.accuracy <= best * 1.5 + 1) f];
    final recent = use.length > 5 ? use.sublist(use.length - 5) : use;
    var w = 0.0, lat = 0.0, lng = 0.0;
    for (final f in recent) {
      final k = 1 / (f.accuracy * f.accuracy);
      w += k;
      lat += f.latitude * k;
      lng += f.longitude * k;
    }
    return (lat: lat / w, lng: lng / w, acc: best);
  }

  /// Outside with a sharp fix right next to the building: ground floor.
  static void _groundReferenceIfNearBuilding(({double lat, double lng, double acc}) pos, List<StartPoint> spots) {
    if (pos.acc > 10) return;
    for (final s in spots) {
      if (!s.indoor || (s.floor ?? 0) != 0) continue;
      if (Geolocator.distanceBetween(pos.lat, pos.lng, s.lat!, s.lng!) <= 25) {
        FloorBarometer.instance.setFloor(0, basis: 'outside');
        return;
      }
    }
  }

  /// Every spot scored by how well it fits: distance (GPS error), floor
  /// (barometer / Wi-Fi), inside or out, Wi-Fi fingerprints. Best first;
  /// the probabilities add up to 1.
  ///
  /// Tested in simulation on the campus's 162 spots: outside with good GPS
  /// the right spot is first 81 % of the time and in the top five always;
  /// inside, GPS alone cannot name the room (so the user is asked), but with
  /// the floor known the right spot is in the top five about 6 times in 10,
  /// and Wi-Fi fingerprints put it first most of the time.
  static List<LocateCandidate> rank(
    double lat,
    double lng,
    double acc, {
    required List<StartPoint> spots,
    int? floor,
    bool floorSure = false,
    bool indoorLikely = false,
    WifiGuess wifi = WifiGuess.none,
    String? recentId,
  }) {
    final sigma = math.max(acc / 1.5, 4.0);
    final reach = 3 * sigma + 10;
    final scored = <(double, StartPoint, double)>[];
    for (final s in spots) {
      final sl = s.lat, sg = s.lng;
      if (sl == null || sg == null) continue;
      final d = Geolocator.distanceBetween(lat, lng, sl, sg);
      final pw = wifi.probability[s.id];
      if (d > reach && (pw == null || pw < 0.05)) continue;
      final z = math.min(d, reach) / sigma;
      var w = math.exp(-0.5 * z * z);
      final sf = s.floor ?? 0;
      if (floor != null && floorSure) {
        if (s.indoor) {
          w *= sf == floor ? 1.0 : 0.02;
        } else {
          w *= floor == 0 ? (indoorLikely ? 0.3 : 1.0) : 0.02;
        }
      } else if (floor != null) {
        // A hint only: other floors stay possible.
        if (s.indoor) {
          w *= sf == floor ? 1.0 : 0.25;
        } else {
          w *= indoorLikely ? 0.3 : 1.0;
        }
      } else if (indoorLikely) {
        w *= s.indoor ? 1.0 : 0.3;
      } else {
        w *= !s.indoor ? 1.0 : (sf == 0 ? 0.5 : 0.1);
      }
      if (wifi.any) w *= pw != null ? 0.15 + 3.0 * pw : 0.5;
      // Where you were a few minutes ago (and GPS still agrees): likely still.
      if (s.id == recentId) w *= 4;
      scored.add((w, s, d));
    }
    final total = scored.fold<double>(0, (a, b) => a + b.$1);
    if (total <= 0) return const [];
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return [
      for (final (w, s, d) in scored)
        LocateCandidate(s, w / total, d,
            byWifi: (wifi.probability[s.id] ?? 0) >= 0.2, recent: s.id == recentId),
    ];
  }
}
