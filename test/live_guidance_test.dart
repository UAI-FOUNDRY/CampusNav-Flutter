import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:campus_navigation/models/route.dart';
import 'package:campus_navigation/models/start_point.dart';
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
        d.feed(mag, t, 0.02, (_, __) => steps++);
      }
      expect(steps, inInclusiveRange(17, 19));

      final lone = StepDetector();
      var bumps = 0;
      for (var i = 0; i < 150; i++) {
        lone.feed(9.81 + (i >= 50 && i < 60 ? 3 : 0), i * 0.02, 0.02, (_, __) => bumps++);
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
        two.feed(mag, t, 0.02, (_, __) => stray++);
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
        d.feed(mag, t, 0.02, (at, __) {
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

    test('a right turn is one segment of about 90 degrees', () {
      final d = TurnDetector();
      final segments = <double>[];
      for (var i = 0; i < 300; i++) {
        final t = i * 0.02;
        final rate = t >= 1 && t < 2.5 ? 60.0 : 0.0; // 1.5 s at 60 deg/s
        d.feed(rate, t, 0.02, (angle, _, __) => segments.add(angle));
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
}
