import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:campus_navigation/models/route.dart';
import 'package:campus_navigation/models/start_point.dart';
import 'package:campus_navigation/services/api_service.dart';
import 'package:campus_navigation/services/floor_barometer.dart';
import 'package:campus_navigation/services/live_guide.dart';
import 'package:campus_navigation/services/motion_sensors.dart';
import 'package:campus_navigation/services/position_filter.dart';
import 'package:campus_navigation/services/route_tracker.dart';
import 'package:campus_navigation/services/spot_locator.dart';
import 'package:campus_navigation/services/wifi_fingerprints.dart';

/// Real answers of GET /api/route (backend repo, October 2026).
NavigationRoute fixture(String name) {
  final json = jsonDecode(File('test/fixtures/$name.json').readAsStringSync());
  return NavigationRoute.fromBackend(Map<String, dynamic>.from(json as Map));
}

void main() {
  // No network in tests (shared Wi-Fi fingerprints, weather ...).
  setUpAll(() => ApiService.useMock = true);

  group('route geometry', () {
    test('the whole route: outside, inside, and the stairs between floors', () {
      final route = fixture('route_gate_innovation_lab');
      final geo = RouteGeometry(route);
      expect(geo.usable, isTrue);
      expect(geo.length, closeTo(263.6, 1.0));
      expect(geo.rides, hasLength(1));
      expect(geo.rides.first.fromFloor, 0);
      expect(geo.rides.first.toFloor, 2);
      expect(geo.rides.first.via, 'stairs');
      expect(geo.stepAlong, hasLength(route.steps.length));
      for (var i = 1; i < geo.stepAlong.length; i++) {
        expect(geo.stepAlong[i], greaterThanOrEqualTo(geo.stepAlong[i - 1]));
      }
      expect(geo.stepAlong.last, geo.length);
      expect(geo.corners.length, greaterThanOrEqualTo(6));
      expect(geo.placeAt(10).indoor, isFalse);
      expect(geo.placeAt(geo.length - 5).floor, 2);
      expect(geo.planNorthAt(geo.length - 5), isNotNull);
    });

    test('stairs and lift steps keep their kind from the backend', () {
      final stairs = fixture('route_lobby_stairs_f2');
      expect(stairs.steps.where((s) => s.type == 'stairs'), hasLength(1));
      final lift = fixture('route_lobby_lift_f2');
      expect(lift.steps.where((s) => s.type == 'lift'), hasLength(1));
      expect(RouteGeometry(lift).rides.single.via, 'lift');
    });

    test('a GPS fix is matched to the right floor line only', () {
      final route = fixture('route_lobby_stairs_f2');
      final geo = RouteGeometry(route);
      final start = geo.at(1).geo;
      final onGround = geo.project(start.lat, start.lng, keys: {'f0'});
      expect(onGround, isNotNull);
      expect(onGround!.along, lessThan(5));
      final onSecond = geo.project(start.lat, start.lng, keys: {'f2'});
      expect(onSecond!.along, greaterThan(geo.rides.first.to - 0.1));
    });
  });

  group('position filter', () {
    test('steps move it at walking speed, a fix pulls it back', () {
      final f = AlongFilter(sigma: 1);
      f.predict(0);
      for (var t = 0.5; t <= 10; t += 0.5) {
        f.predict(t);
        f.updateVelocity(1.3, 0.04);
      }
      expect(f.s, closeTo(12.5, 1.5));
      f.updatePosition(10, 1);
      expect(f.s, lessThan(12));
      expect(f.at(f.t! + 1), greaterThan(f.s)); // still walking
    });
  });

  group('sensors', () {
    test('steps are counted from the third bump of a steady rhythm', () {
      final d = StepDetector();
      var steps = 0;
      for (var i = 0; i < 500; i++) {
        final t = i * 0.02; // 10 s at 50 Hz, 1.85 steps a second
        final mag = 9.81 + 2 * math.sin(2 * math.pi * 1.85 * t); // with gravity
        d.feed(mag, t, 0.02, (_, _) => steps++);
      }
      expect(steps, inInclusiveRange(17, 19));

      final lone = StepDetector();
      var bumps = 0;
      for (var i = 0; i < 150; i++) {
        lone.feed(9.81 + (i >= 50 && i < 60 ? 3 : 0), i * 0.02, 0.02, (_, _) => bumps++);
      }
      expect(bumps, 0); // putting the phone down is not walking

      // Two bumps a second apart (the hand, in a lift) are not a walk either.
      final two = StepDetector();
      var stray = 0;
      for (var i = 0; i < 300; i++) {
        final t = 0.02 * i;
        var mag = 9.81;
        if (t >= 2 && t < 2.3) mag += 2 * math.sin(math.pi * (t - 2) / 0.3);
        if (t >= 3 && t < 3.3) mag += 2 * math.sin(math.pi * (t - 3) / 0.3);
        two.feed(mag, t, 0.02, (_, _) => stray++);
      }
      expect(stray, 0);
    });

    test('gentle steps on the level still count right after strong stair steps', () {
      final d = StepDetector();
      var level = 0;
      var t = 0.0;
      // 12 s of strong steps (stairs, 1.5 a second), then 12 s of gentle
      // walking (1.8 a second) with the phone held steady.
      for (var i = 0; i < 1200; i++, t += 0.02) {
        final strong = t < 12;
        final amp = strong ? 4.0 : 0.6;
        final rate = strong ? 1.5 : 1.8;
        final mag = 9.81 + amp * math.sin(2 * math.pi * rate * t);
        d.feed(mag, t, 0.02, (at, _) {
          if (at >= 12) level++;
        });
      }
      expect(level, greaterThanOrEqualTo(17)); // of about 21 (none before the fix)
    });

    // Vertical acceleration of a lift ride (smooth start and stop pushes),
    // plus a swaying hand and a sensor offset.
    List<double> liftRide(int floors, {double h = 3.5, double vmax = 1.0, double acc = 0.7}) {
      final dist = floors.abs() * h;
      final ta = vmax / acc;
      final tc = (dist - vmax * ta) / vmax;
      double bump(double u) => u >= 0 && u < ta ? acc * 2 * math.pow(math.sin(math.pi * u / ta), 2) : 0.0;
      final out = <double>[];
      const wait = 5.0;
      for (var t = 0.0; t < wait + 2 * ta + tc + 6; t += 0.02) {
        final u = t - wait;
        final a = (floors < 0 ? -1.0 : 1.0) * (bump(u) - bump(u - ta - tc));
        out.add(a + 0.05 * math.sin(2 * math.pi * 1.3 * t) + 0.03);
      }
      return out;
    }

    test('a lift ride: the floors from the start and stop pushes', () {
      for (final floors in [1, -2]) {
        final m = LiftMeter();
        final rides = <double>[];
        final a = liftRide(floors);
        for (var i = 0; i < a.length; i++) {
          final h = m.feed(a[i], 0.02 * i, 0.02);
          if (h != null) rides.add(h);
        }
        expect(rides, hasLength(1));
        expect(rides.single, closeTo(floors * 3.5, 0.6));
        expect(m.riding, isFalse);
      }
    });

    test('moving the phone up and down is not a lift ride', () {
      final m = LiftMeter();
      var rides = 0;
      for (var i = 0; i < 750; i++) {
        final t = 0.02 * i;
        var a = 0.03 + 0.05 * math.sin(2 * math.pi * 1.3 * t);
        if (t >= 6 && t < 6.6) a += 2.0 * math.sin(2 * math.pi * (t - 6) / 0.6);
        if (m.feed(a, t, 0.02) != null) rides++;
      }
      expect(rides, 0);
      expect(m.riding, isFalse);
    });

    // A jerk-limited lift (how real lifts move): 5 s still, the acceleration
    // ramps up at [jerk], holds [peak] for [hold] s and ramps down, the lift
    // cruises [cruise] s, brakes the same way, then 6 s still; with a
    // swaying hand and a sensor offset. Returns the samples and the height.
    (List<double>, double) jerkLift({
      required int dir,
      required double peak,
      required double jerk,
      required double hold,
      required double cruise,
    }) {
      final ramp = peak / jerk;
      final push = <double>[];
      for (var t = 0.0; t < 2 * ramp + hold; t += 0.02) {
        push.add(t < ramp
            ? jerk * t
            : t < ramp + hold
                ? peak
                : math.max(0.0, peak - jerk * (t - ramp - hold)));
      }
      final sign = dir.toDouble();
      final clean = <double>[
        for (var i = 0; i < 250; i++) 0.0,
        for (final a in push) sign * a,
        for (var i = 0; i < (cruise / 0.02).round(); i++) 0.0,
        for (final a in push) -sign * a,
        for (var i = 0; i < 300; i++) 0.0,
      ];
      var v = 0.0, h = 0.0;
      for (final a in clean) {
        v += a * 0.02;
        h += v * 0.02;
      }
      final noisy = <double>[
        for (var i = 0; i < clean.length; i++) clean[i] + 0.12 * math.sin(2 * math.pi * 1.3 * i * 0.02) + 0.12,
      ];
      return (noisy, h);
    }

    test('fast and ordinary lifts, one floor or more', () {
      // The first never reaches a steady speed on one short floor: its stop
      // push comes 1.5 s after the start (a hand moved up and back is faster).
      final cases = [
        jerkLift(dir: -1, peak: 1.5, jerk: 1.8, hold: 0.25, cruise: 0),
        jerkLift(dir: 1, peak: 1.5, jerk: 1.8, hold: 0.25, cruise: 0),
        jerkLift(dir: 1, peak: 0.8, jerk: 1.0, hold: 0.45, cruise: 6),
        jerkLift(dir: -1, peak: 0.8, jerk: 1.0, hold: 0.45, cruise: 2.6),
      ];
      for (final (a, height) in cases) {
        final m = LiftMeter();
        final rides = <double>[];
        for (var i = 0; i < a.length; i++) {
          final h = m.feed(a[i], 0.02 * i, 0.02);
          if (h != null) rides.add(h);
        }
        expect(rides, hasLength(1), reason: 'a ride of ${height.toStringAsFixed(1)} m');
        expect(rides.single, closeTo(height, 0.2 * height.abs() + 0.4));
        expect(m.riding, isFalse);
      }
    });

    test('a right turn is one segment of about 90 degrees', () {
      final d = TurnDetector();
      final segments = <double>[];
      for (var i = 0; i < 300; i++) {
        final t = i * 0.02;
        final rate = t >= 1 && t < 2.5 ? 60.0 : 0.0; // 1.5 s at 60 deg/s
        d.feed(rate, t, 0.02, (angle, _, _) => segments.add(angle));
      }
      expect(segments, hasLength(1));
      expect(segments.first, closeTo(90, 8));
    });
  });

  group('use my location', () {
    const spots = [
      StartPoint(id: 'lobby', name: 'Admin Lobby', hint: '', indoor: true, floor: 0, lat: 18.90281, lng: 73.37467),
      StartPoint(id: 'office', name: 'Director Office', hint: '', indoor: true, floor: 1, lat: 18.90281, lng: 73.37468),
      StartPoint(id: 'vending', name: 'Vending machine', hint: '', lat: 18.90300, lng: 73.37480),
    ];

    test('inside, the outdoor spot does not win just for being near', () {
      final ranked = SpotLocator.rank(18.90285, 73.37470, 25,
          spots: spots, floor: 0, floorSure: true, indoorLikely: true);
      expect(ranked.first.spot.id, 'lobby');
      expect(ranked.firstWhere((c) => c.spot.id == 'office').probability, lessThan(0.05));
    });

    test('Wi-Fi fingerprints: same place close, other place far', () {
      const a = {'aa:00:00:00:00:01': -50.0, 'aa:00:00:00:00:02': -60.0, 'aa:00:00:00:00:03': -70.0};
      const b = {'aa:00:00:00:00:01': -52.0, 'aa:00:00:00:00:02': -61.0, 'aa:00:00:00:00:03': -69.0};
      const c = {'bb:00:00:00:00:01': -50.0, 'bb:00:00:00:00:02': -60.0, 'bb:00:00:00:00:03': -70.0};
      expect(WifiFingerprints.distance(a, b), lessThan(2));
      expect(WifiFingerprints.distance(a, c), isNull); // nothing in common
    });

    test('Wi-Fi fingerprints from another phone: its offset is taken out', () {
      const a = {
        'aa:00:00:00:00:01': -50.0,
        'aa:00:00:00:00:02': -60.0,
        'aa:00:00:00:00:03': -70.0,
        'aa:00:00:00:00:04': -78.0,
      };
      // The same place, heard by a phone that reads everything 8 dB weaker.
      final weaker = {for (final e in a.entries) e.key: e.value - 8};
      expect(WifiFingerprints.distance(a, weaker), greaterThan(7));
      expect(WifiFingerprints.distance(a, weaker, otherPhone: true), lessThan(1.5));
      // Another place (the same networks, the order turned round) stays far.
      const elsewhere = {
        'aa:00:00:00:00:01': -78.0,
        'aa:00:00:00:00:02': -70.0,
        'aa:00:00:00:00:03': -60.0,
        'aa:00:00:00:00:04': -50.0,
      };
      expect(WifiFingerprints.distance(a, elsewhere, otherPhone: true), greaterThan(15));
    });
  });

  group('live guide', () {
    test('Next walks into the stairs card; the floor confirms it', () {
      final route = fixture('route_lobby_stairs_f2');
      final guide = LiveGuide(route: route);
      final stairs = route.steps.indexWhere((s) => s.type == 'stairs');
      guide.jumpToStep(stairs);
      final wait = guide.wait;
      expect(wait, isNotNull);
      expect(wait!.to, 2);
      expect(guide.stepIndex, stairs);

      guide.confirmFloor();
      expect(guide.wait, isNull);
      expect(guide.pose.value!.floor, 2);
      expect(guide.stepIndex, stairs + 1);
      expect(guide.takeNotice(), contains('floor 2'));
      guide.dispose();
    });

    test('the last step means arrived', () {
      final route = fixture('route_lobby_lift_f2');
      final guide = LiveGuide(route: route);
      guide.jumpToStep(route.steps.length - 1);
      expect(guide.arrived, isTrue);
      expect(guide.remaining, lessThan(1));
      guide.dispose();
    });

    test('metres count down from the start', () {
      final route = fixture('route_gate_innovation_lab');
      final guide = LiveGuide(route: route);
      guide.frame(0);
      expect(guide.remaining, closeTo(route.distance, route.distance * 0.25));
      expect(guide.stepIndex, 1);
      expect(guide.pose.value!.indoor, isFalse);
      guide.dispose();
    });
  });

  // Whole trips on real campus routes, with the sensors replayed as a phone
  // delivers them (steps, air pressure, GPS outside) on a test clock.
  group('whole trips', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FloorBarometer.weatherEnabled = false;
      final baro = FloorBarometer.instance;
      baro.available = true;
      baro.pressure.value = null;
      baro.hPaPerFloor = FloorBarometer.metresPerFloor * FloorBarometer.hPaPerMetre;
    });
    tearDown(() => SensorClock.debugTime = null);

    test('stairs with a barometer: the card closes by itself on the new floor', () {
      final guide = LiveGuide(route: fixture('route_lobby_stairs_f2'), startFloorKnown: true);
      final trip = _Trip(guide);
      final ride = guide.geometry.rides.single;

      trip.walk(60, until: () => guide.wait != null);
      expect(guide.wait, isNotNull, reason: 'the stairs card at the stairs');
      expect(trip.maxError, lessThan(4), reason: 'the arrow follows the steps');

      trip.climb(ride, 24, stepGap: 38);
      expect(guide.wait, isNull, reason: 'closed by the barometer, no tap');
      expect(trip.notices, contains("You're on floor 2"));

      // At the top the arrow waits for the air pressure to settle (a few
      // seconds), then catches up.
      trip.walk(10);
      expect(trip.error, lessThan(4.5), reason: 'caught up after the stairs');
      trip.maxError = 0;
      trip.walk(60, until: () => trip.truth >= guide.geometry.length);
      trip.stand(4);
      expect(guide.arrived, isTrue);
      expect(guide.pose.value!.floor, 2);
      expect(trip.maxError, lessThan(4.5), reason: 'on the new floor too');
      expect(trip.stepsInOrder, isTrue);
      guide.dispose();
    });

    test('stairs without a barometer: closed by counting steps, and learned', () {
      final guide = LiveGuide(route: fixture('route_lobby_stairs_f2'), startFloorKnown: true);
      final trip = _Trip(guide, barometer: false);
      final ride = guide.geometry.rides.single;
      expect(guide.stairStepsPerFloor, GuideTuning.defaultStairStepsPerFloor);

      trip.walk(60, until: () => guide.wait != null);
      expect(guide.wait, isNotNull);
      // These stairs have 26 steps a floor; the app expects 24 at first.
      trip.climb(ride, 0, steps: 52, stepGap: 38);
      expect(guide.wait, isNull, reason: 'closed at the full count');
      expect(trip.notices, contains("You're on floor 2"));

      // Back on the level: the extra steps had the stairs' rhythm, so they
      // did not move the arrow, and the count is learned (24 -> 25).
      trip.walk(3);
      expect(guide.stairStepsPerFloor, closeTo(25, 0.01));
      trip.walk(60, until: () => trip.truth >= guide.geometry.length);
      trip.stand(4);
      expect(guide.arrived, isTrue);
      expect(trip.stepsInOrder, isTrue);
      guide.dispose();
    });

    test('gate to the Innovation Lab: GPS outside, steps inside, stairs to floor 2', () {
      final guide = LiveGuide(route: fixture('route_gate_innovation_lab'));
      final trip = _Trip(guide, gps: true);
      final geo = guide.geometry;
      final ride = geo.rides.single;

      // Outside, as far as the door.
      trip.walk(300, until: () => geo.placeAt(trip.truth).indoor);
      expect(trip.maxError, lessThan(5), reason: 'GPS and steps outside');
      trip.walk(3);
      expect(guide.pose.value!.indoor, isTrue);

      // Inside to the stairs, then up.
      trip.maxError = 0;
      trip.walk(120, until: () => guide.wait != null);
      expect(guide.wait, isNotNull);
      expect(trip.maxError, lessThan(5), reason: 'steps inside');
      trip.climb(ride, 24, stepGap: 38);
      expect(guide.wait, isNull);
      expect(trip.notices, contains("You're on floor 2"));

      trip.walk(10);
      trip.maxError = 0;
      trip.walk(120, until: () => trip.truth >= geo.length);
      trip.stand(4);
      expect(guide.arrived, isTrue);
      expect(trip.maxError, lessThan(4.5), reason: 'steps on floor 2');
      expect(guide.stepIndex, guide.route.steps.length - 1);
      expect(trip.stepsInOrder, isTrue);
      guide.dispose();
    });

    test('GPS far off the path asks for a new route', () {
      final guide = LiveGuide(route: fixture('route_gate_innovation_lab'));
      final trip = _Trip(guide, gps: true);
      trip.walk(25);
      expect(guide.rerouteRequest, isNull);
      trip.walk(5, offPath: 45);
      expect(guide.rerouteRequest, isNotNull);
      expect(guide.pose.value!.offRoute, isTrue);
      guide.dispose();
    });
  });
}

/// Replays a walk into a [LiveGuide] the way the phone delivers it: a step
/// every few ticks, air pressure 5 times a second, a GPS fix every second
/// while outside, and the guide's tick and frame 10 times a second. Time
/// runs in ticks of 20 ms on [SensorClock.debugTime].
class _Trip {
  _Trip(this.guide, {this.barometer = true, this.gps = false}) {
    SensorClock.debugTime = _time;
    guide.debugStart();
  }

  final LiveGuide guide;
  final bool barometer;
  final bool gps;
  RouteGeometry get geo => guide.geometry;

  static const double _dt = 0.02;
  int _n = 0; // ticks so far
  double get _time => 100 + _n * _dt;

  /// Where the walker really is (metres along the route).
  double truth = 0;

  /// Air pressure where the walker is (hPa).
  double hPa = 1005;

  int? _lastStepN;
  final notices = <String>[];
  final _stepIndexes = <int>[];

  /// The largest gap between the arrow and the walker (reset it freely).
  double maxError = 0;

  /// The gap between the arrow and the walker now (metres).
  double get error => ((guide.pose.value?.along ?? 0) - truth).abs();

  bool get stepsInOrder {
    for (var i = 1; i < _stepIndexes.length; i++) {
      if (_stepIndexes[i] < _stepIndexes[i - 1]) return false;
    }
    return true;
  }

  /// Walks on the level for up to [seconds] (0.72 m steps every [stepGap]
  /// ticks), stopping early once [until] is true. [offPath]: GPS puts you
  /// that many metres to the side of the path.
  void walk(double seconds, {int stepGap = 28, bool Function()? until, double offPath = 0}) {
    final end = _n + (seconds / _dt).round();
    final speed = GuideTuning.defaultStepLength / (stepGap * _dt);
    while (_n < end && !(until?.call() ?? false)) {
      _advance(stepGap: stepGap, speed: speed, offPath: offPath);
    }
  }

  /// Stands still for [seconds].
  void stand(double seconds) {
    final end = _n + (seconds / _dt).round();
    while (_n < end) {
      _advance();
    }
  }

  /// Climbs [ride] (stairs): a step every [stepGap] ticks for [seconds], or
  /// [steps] steps; the air pressure changes by the floors climbed as a
  /// barometer would see it. At the top the walker is at the ride's end.
  void climb(FloorRide ride, double seconds, {int stepGap = 38, int? steps}) {
    final n = steps ?? (seconds / (stepGap * _dt)).round();
    final ticks = n * stepGap;
    // Up: the pressure falls.
    final total = -ride.floors * FloorBarometer.instance.hPaPerFloor;
    for (var i = 0; i < ticks; i++) {
      _advance(stepGap: stepGap, hPaPerTick: total / ticks, onRide: true);
    }
    truth = ride.to;
  }

  void _advance({int? stepGap, double speed = 0, double hPaPerTick = 0, double offPath = 0, bool onRide = false}) {
    _n++;
    final t = _time;
    SensorClock.debugTime = t;
    if (!onRide) truth = math.min(geo.length, truth + speed * _dt);
    hPa += hPaPerTick;

    final last = _lastStepN;
    if (stepGap != null && (last == null || _n - last >= stepGap)) {
      final gap = last == null ? null : (_n - last) * _dt;
      guide.debugStep(t, gap != null && gap <= 2.0 ? gap : null);
      _lastStepN = _n;
    }
    if (barometer && _n % 10 == 0) FloorBarometer.instance.add(hPa, t);
    if (gps && _n % 50 == 0 && !onRide && !geo.placeAt(truth).indoor) {
      guide.debugFix(_fix(speed, offPath));
    }
    if (_n % 5 == 0) {
      guide.debugTick();
      guide.frame(t);
      final notice = guide.takeNotice();
      if (notice != null) notices.add(notice);
      _stepIndexes.add(guide.stepIndex);
      final shown = guide.pose.value?.along;
      if (shown != null && !onRide && guide.wait == null) {
        maxError = math.max(maxError, (shown - truth).abs());
      }
    }
  }

  /// A sharp GPS fix where the walker is ([offPath] metres to the right).
  Position _fix(double speed, double offPath) {
    final spot = geo.at(truth);
    var lat = spot.geo.lat, lng = spot.geo.lng;
    if (offPath != 0) {
      final side = (spot.bearing + 90) * math.pi / 180;
      lat += offPath * math.cos(side) / 110574;
      lng += offPath * math.sin(side) / (111320 * math.cos(lat * math.pi / 180));
    }
    return Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: spot.bearing,
      headingAccuracy: 0,
      speed: speed,
      speedAccuracy: 0.3,
    );
  }
}
