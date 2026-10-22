part of 'live_guide.dart';

// Which floor you are on: the stairs / lift card and how it closes by
// itself, the barometer, and (without a barometer) counted stair steps,
// felt lift rides and the Wi-Fi floor.
//
// An extension of LiveGuide (same library), so it reads and writes the
// guide's state directly. The tuning values are in GuideTuning.
extension _FloorSensing on LiveGuide {
  /// The counts below belong to the ride you are at now.
  FloorRide? _trackRide() {
    final r = _holdRide;
    if (r == null) return null;
    if (_rideFor != r) {
      _rideFor = r;
      _rideSteps = 0;
      _rideYaw0 = _motion.turns.yaw;
      _rideGaps.clear();
      _levelGap = _recentLevelGap();
      _liftRight = 0;
      _liftPushes = 0;
      _liftStartAt = null;
      _liftEnteredAt = null;
      _liftPushInside = false;
      _liftWalk = 0;
      _liftLastStepT = -1e9;
      _liftStills = 0;
      _liftStillCounted = false;
      _liftSince = SensorClock.now();
      _liftStillSince = _liftSince;
    }
    return r;
  }

  /// Your usual time between steps on the level (median of the last ten,
  /// before the stairs), or null if you have not walked enough.
  double? _recentLevelGap() {
    final times = _stepTimes.toList();
    final gaps = <double>[
      for (var i = 1; i < times.length; i++)
        if (times[i] - times[i - 1] >= 0.3 && times[i] - times[i - 1] <= 1.2) times[i] - times[i - 1],
    ];
    if (gaps.length < 6) return null;
    final last = gaps.sublist(math.max(0, gaps.length - 10))..sort();
    return last[last.length ~/ 2];
  }

  // ------------------------------------------------- stairs (no barometer)
  //
  // The card closes when the progress bar is full: [_stairSteps] steps a
  // floor (24 to begin with, then learned for your stairs), or earlier on
  // dog-leg stairs once you turned round once a floor (gyroscope), or when
  // your walking rhythm says the stairs are over.
  //
  // The rhythm: climbing stairs is clearly slower than walking on the level
  // (about 10-30 %). Stairs shorter than the count: your steps are back to
  // the level rhythm before the bar is full, so the card closes then. Stairs
  // longer: the card closes at the full bar, and the steps that still have
  // the stairs' rhythm do not move the arrow along the new floor. Either way
  // the steps this staircase has per floor are learned, without a tap.
  //
  // Simulated with 16-32 step staircases, mid landings and an uneven gait:
  // going up, the per-floor count is learned within a few climbs.

  /// (level gap, stairs gap) when climbing these stairs has its own rhythm
  /// (at least 12 % slower or faster than walking), else null.
  (double, double)? _rhythm({int skipLast = 0}) {
    final level = _levelGap;
    final n = _rideGaps.length - skipLast;
    if (level == null || n < 8) return null;
    final body = _rideGaps.sublist(1, n)..sort();
    final stairs = body[body.length ~/ 2];
    if ((stairs / level - 1).abs() < 0.12) return null;
    return (level, stairs);
  }

  static bool _levelLike(double gap, double level, double stairs) =>
      (gap - level).abs() < (gap - stairs).abs() && (gap / level - 1).abs() <= 0.12;

  /// Steps at the end of [_rideGaps] that already have the level rhythm.
  int _trailingLevel(double level, double stairs) {
    var k = 0;
    for (var i = _rideGaps.length - 1; i >= 0 && k < 8; i--) {
      if (!_levelLike(_rideGaps[i], level, stairs)) break;
      k++;
    }
    return k;
  }

  void _learnStairs(FloorRide r, int steps) {
    if (r.floors == 0 || steps < 8) return;
    final perFloor = steps / r.floors.abs();
    _stairSteps = (0.5 * _stairSteps + 0.5 * perFloor).clamp(GuideTuning.minStairStepsPerFloor, GuideTuning.maxStairStepsPerFloor).toDouble();
    _saveStairSteps();
  }

  /// The top of the stairs: close the card, and learn from the rhythm.
  void _stairsDone(FloorRide r, double expected) {
    final rh = _rhythm(skipLast: 3);
    var walked = 0.0;
    if (rh != null) {
      final (level, stairs) = rh;
      final k = _trailingLevel(level, stairs);
      if (k >= 2) {
        // Already walking on the level for k steps: shorter stairs.
        _learnStairs(r, _rideSteps - k);
        walked = _stepLength * k;
      } else {
        // Still climbing at the full count: the steps that keep the stairs'
        // rhythm do not move the arrow; then the count is learned.
        _absorbLevel = level;
        _absorbStair = stairs;
        _absorbBase = _rideSteps;
        _absorbFloors = r.floors.abs();
        _absorbLeft = (0.6 * expected).ceil();
        _absorbSteps = 0;
        _absorbLevelRun = 0;
      }
    }
    _confirm(r, walked: walked, by: 'steps');
  }

  /// After the card closed at a full count: a step with the stairs' rhythm
  /// (true: it does not move the arrow) or the level one.
  bool _absorbStep(double? gap) {
    final level = _absorbLevel, stairs = _absorbStair;
    if (level == null || stairs == null || gap == null) return false;
    if ((gap - stairs).abs() < (gap - level).abs()) {
      _absorbSteps++;
      _absorbLevelRun = 0;
      if (--_absorbLeft <= 0) _absorbLevel = _absorbStair = null;
      return true;
    }
    if (++_absorbLevelRun >= 2) {
      final floors = _absorbFloors;
      _absorbLevel = _absorbStair = null;
      if (floors > 0) {
        final perFloor = (_absorbBase + _absorbSteps) / floors;
        _stairSteps = (0.5 * _stairSteps + 0.5 * perFloor).clamp(GuideTuning.minStairStepsPerFloor, GuideTuning.maxStairStepsPerFloor).toDouble();
        _saveStairSteps();
      }
    }
    return false;
  }

  /// A step while the card is up (stairs or lift).
  void _stairStep([double? gap]) {
    final r = _trackRide();
    if (r == null) return;
    _rideSteps++;
    if (gap != null) _rideGaps.add(gap);
    if (hasBarometer || r.floors == 0) return;
    if (r.via == 'lift') {
      _liftStep();
      return;
    }
    if (r.via != 'stairs') return;
    final floors = r.floors.abs();
    final expected = _stairSteps * floors;
    // 1) Back to the level rhythm before the count is full: shorter stairs.
    final rh = _rhythm(skipLast: 5);
    if (rh != null && _rideSteps >= 0.6 * expected + 5) {
      final (level, stairs) = rh;
      final last = _rideGaps.sublist(_rideGaps.length - 5);
      if (last.where((g) => _levelLike(g, level, stairs)).length >= 4) {
        _learnStairs(r, _rideSteps - 5);
        _confirm(r, walked: _stepLength * 5, by: 'steps');
        return;
      }
    }
    // 2) Dog-leg / spiral stairs: a full turn round a floor (gyroscope;
    //    a compass is bent by the steel of a stairwell).
    final turned = (_motion.turns.yaw - _rideYaw0).abs();
    if (_motion.hasGyroscope && _rideSteps >= 0.8 * expected && turned >= 330.0 * floors) {
      _stairsDone(r, expected);
      return;
    }
    // 3) The count: the bar is full, the card closes.
    if (_rideSteps >= expected) _stairsDone(r, expected);
  }

  // --------------------------------------------------- lift (no barometer)
  //
  // The lift is felt by its start push and its stop push (see LiftMeter).
  // The card closes:
  //  - when the lift stops after taking you the route's way (one floor: any
  //    such ride; more: once the floors add up);
  //  - when only the stop was felt (the start was missed): a push the other
  //    way while you stand in the lift;
  //  - when only the start was felt: once the lift must have arrived at the
  //    speed measured, while you still stand in it;
  //  - otherwise as you walk out: six steps after a push felt in the lift,
  //    eight after any push, six after you stood still twice (waiting, then
  //    riding), twelve after standing once for 20 s or more.
  // "In the lift" means after the walk that took you in.
  //
  // Simulated on whole trips (walk to the lift, wait 3-40 s with a fidgeting
  // hand, step in, ride 1-3 floors, walk out): the card closes as the lift
  // stops in about 90 % of trips (100 % with a calm hand), about 1 % before
  // the ride, the rest as you walk out; it never stays up.

  void _liftStep() {
    final t = _stepTimes.isEmpty ? SensorClock.now() : _stepTimes.last;
    _liftWalk = t - _liftLastStepT <= 1.5 ? _liftWalk + 1 : 1;
    _liftLastStepT = t;
    if (_liftWalk >= 2) {
      _liftStillCounted = false;
      _liftEnteredAt = t; // the latest walk ends here, for now
    }
    final r = _holdRide;
    if (r == null) return;
    final felt = _liftRight > 0 || _liftPushInside;
    if ((felt && _liftWalk >= 6) ||
        (_liftPushes > 0 && _liftWalk >= 8) ||
        (_liftStills >= 2 && _liftWalk >= 6) ||
        (_liftStills >= 1 && t - _liftSince >= 20 && _liftWalk >= 12)) {
      _confirm(r, walked: _stepLength * _liftWalk, by: 'lift');
    }
  }

  /// Every tick at the lift: standing still (5 s counts once per stand), and
  /// "it must have arrived" after a start the route's way.
  void _liftTick(double t) {
    final r = _holdRide;
    if (hasBarometer || r == null || r.via != 'lift' || !_waiting || r.floors == 0) return;
    _trackRide();
    final walking = _motion.walkingAt(t);
    if (walking) {
      _liftStillSince = null;
    } else {
      final since = _liftStillSince ??= t;
      if (t - since >= 5.0 && !_liftStillCounted) {
        _liftStills++;
        _liftStillCounted = true;
      }
    }
    final start = _liftStartAt, entered = _liftEnteredAt;
    final lift = _motion.lift;
    if (start != null && entered != null && start > entered && !walking &&
        lift.riding && lift.direction * r.floors > 0) {
      final due = start + _metresPerFloor * r.floors.abs() / math.max(_liftStartSpeed, 0.3) + 3.0;
      if (t >= due) _confirm(r, by: 'lift');
    }
  }

  /// The lift was felt starting ([direction] +1 up, -1 down).
  void _liftStarted(int direction, double startedAt, double speed) {
    if (!_running || _paused || _simulating || hasBarometer) return;
    final hold = _holdRide;
    if (hold == null || hold.via != 'lift' || hold.from - _f.s > 15) return;
    final r = _trackRide();
    if (r == null || r.floors == 0) return;
    _liftPushes++;
    final entered = _liftEnteredAt;
    final inside = entered != null && startedAt > entered;
    _liftPushInside = inside;
    if (direction * r.floors > 0) {
      _liftStartAt = startedAt;
      _liftStartSpeed = speed;
    } else if (_liftStartAt == null && inside && _waiting) {
      // The route's way was never felt starting, but here is a push the
      // other way while you stand in the lift: the lift stopping.
      final still = _liftStillSince;
      if (still != null && SensorClock.now() - still >= 3.0) {
        _confirm(r, by: 'lift');
        return;
      }
    }
    _changed();
  }

  /// A whole lift ride felt by the accelerometer ([metres] up, + or -).
  void _liftRide(double metres) {
    if (!_running || _paused || _simulating || hasBarometer || metres.abs() < 1.0) return;
    final hold = _holdRide;
    if (hold == null || hold.via != 'lift' || hold.from - _f.s > 15) return;
    final r = _trackRide();
    if (r == null || r.floors == 0) return;
    if (metres * r.floors > 0) {
      _liftRight += metres.abs();
      final floors = _liftRight / _metresPerFloor;
      final want = r.floors.abs();
      if (want == 1 || floors >= want - 0.65) {
        // The lift has stopped on the route's floor: learn how high a floor is.
        final perFloor = _liftRight / want;
        if (perFloor >= 2.7 && perFloor <= 6.0) {
          _baro.learnFloorHeight(perFloor * FloorBarometer.hPaPerMetre);
        }
        _confirm(r, by: 'lift');
        return;
      }
    }
    _changed();
  }

  Future<void> _saveStairSteps() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('guide.stairSteps', _stairSteps);
    } catch (_) {}
  }

  /// Without a barometer, on Android: every 40 s inside, the Wi-Fi around is
  /// compared with the learned fingerprints. Two scans in a row on another
  /// floor than the route: "You seem to be on floor N".
  Future<void> _wifiFloorCheck(double t) async {
    final wifi = WifiFingerprints.instance;
    if (_wifiBusy || hasBarometer || !wifi.supported || t - _wifiAt < 40 || _waiting) return;
    final place = _geo.placeAt(_f.s);
    if (!place.indoor) return;
    _wifiBusy = true;
    _wifiAt = t;
    try {
      await wifi.load();
      if (wifi.spotCount == 0) return;
      final scan = await wifi.scan();
      if (scan == null || !_running) return;
      final spots = <String, StartPoint>{
        for (final s in ApiService.cachedCatalog?.starts ?? const <StartPoint>[]) s.id: s,
      };
      final floor = wifi.guess(scan, spots).floor;
      if (floor == null) return;
      final routeFloor = _geo.placeAt(_f.s).floor;
      if (floor == routeFloor) {
        _wifiAgree = 0;
        _wifiFloor = null;
        return;
      }
      _wifiAgree = _wifiFloor == floor ? _wifiAgree + 1 : 1;
      _wifiFloor = floor;
      if (_wifiAgree >= 2 && _mismatch != floor) {
        _floorOffset = floor - routeFloor;
        _mismatch = floor;
        _changed();
      }
    } finally {
      _wifiBusy = false;
    }
  }

  /// Walking in or out of the building's ground floor: the door is on the
  /// ground floor, a perfect moment for the barometer's reference.
  void _doorReference() {
    final place = _geo.placeAt(_f.s);
    final was = _wasIndoor;
    _wasIndoor = place.indoor;
    if (was == null || was == place.indoor || _climbing || _simulating) return;
    if (place.floor == 0 && _f.sigma < 8) _baro.setFloor(0, basis: 'door');
  }

  /// Outside with a sharp fix right next to the building: ground floor.
  void _outsideReference(Position p, bool indoor, double t) {
    if (indoor || p.accuracy > 10 || _climbing || t - _lastOutsideRef < 60) return;
    final near = _geo.project(p.latitude, p.longitude, keys: const {'f0'});
    if (near == null || near.off > 25) return;
    _lastOutsideRef = t;
    _baro.setFloor(0, basis: 'outside');
  }

  /// Floors from air pressure, in climb episodes: while the pressure changes
  /// you are on stairs or in a lift (steps do not move you along the floor);
  /// when it settles, the change is counted in whole floors and compared
  /// with the route.
  void _pressureChanged(double p, double t) {
    _press.add(p, t);
    final ref = _startRefFloor;
    if (ref != null) {
      _startRefFloor = null;
      _baro.setFloor(ref, basis: 'start');
    }
    if (!_running || _simulating) return;
    final p5 = _press.ago(t, 5.0), p3 = _press.ago(t, 3.0);
    if (p5 == null || p3 == null) return;
    final d5 = p - p5, d3 = p - p3;
    if (!_climbing) {
      if (d5.abs() > GuideTuning.climbHpa) {
        final since = _fastSince ??= t;
        if (t - since >= 0.5) {
          _climbing = true;
          _calmSince = null;
          // Pressure on the floor we are leaving: just before the change began.
          _p0 ??= _press.ago(t, 6.0) ?? p5;
          _changed();
        }
      } else {
        _fastSince = null;
      }
      return;
    }

    // Climbing. Near the route's stairs / lift: on the new floor already?
    final r = _holdRide;
    final p0 = _p0;
    if (r != null && p0 != null && r.from - _f.s <= GuideTuning.rideNearMetres) {
      final expected = r.floors;
      final floors = (p0 - p) / _baro.hPaPerFloor;
      final p15 = _press.ago(t, 1.5);
      final slowing = p15 != null && (p - p15).abs() < 0.03;
      final off = (floors - expected).abs();
      if (off <= 0.15 || (off <= 0.3 && slowing)) {
        _learnP0 = p0;
        _learnFloors = expected;
        _confirm(r, by: 'barometer');
        _p0 = null;
        _pendingExtra = true;
      }
    }
    if (d3.abs() < GuideTuning.calmHpa) {
      final calm = _calmSince ??= t;
      if (t - calm >= GuideTuning.calmHoldSeconds) {
        _climbing = false;
        _fastSince = null;
        _climbEndT = calm - 2.0;
        if (_pendingExtra) {
          // The floor was confirmed during the climb; the steps taken on
          // the new floor since the climb ended still count.
          final n = _stepsSince(calm - 2.0);
          _f.s = math.min(_geo.length, _f.s + math.min(10.0, _stepLength * n));
          _pendingExtra = false;
          _p0 = null;
          final lp0 = _learnP0;
          if (lp0 != null && _learnFloors != 0) {
            _baro.learnFloorHeight((lp0 - p).abs() / _learnFloors.abs());
          }
          final place = _geo.placeAt(_f.s);
          if (place.indoor) _baro.setFloor(place.floor, basis: 'stairs');
          _clamp();
        } else {
          _settled(t, p);
        }
        _changed();
      }
    } else {
      _calmSince = null;
    }
  }

  /// A climb just ended: how many floors, and was it the route's stairs/lift?
  void _settled(double t, double p) {
    final p0 = _p0;
    if (p0 == null) return;
    final floors = (p0 - p) / _baro.hPaPerFloor;
    final n = floors.round();
    final r = _holdRide;
    final expected = r?.floors ?? 0;
    final close = r != null && r.from - _f.s <= GuideTuning.rideNearMetres;
    if (n == 0) {
      if (!close) _p0 = null; // a ramp or a pressure blip: forget it
      return;
    }
    if (r != null && close && n == expected && (floors - n).abs() <= 0.45) {
      _confirm(r, base: p0, afterClimb: true, by: 'barometer');
      _p0 = null;
      final place = _geo.placeAt(_f.s);
      if (place.indoor) _baro.setFloor(place.floor, basis: r.via);
      return;
    }
    if (r != null && close && n * expected > 0 && n.abs() < expected.abs()) {
      return; // a lift stopping on the way: keep counting from p0
    }
    _p0 = null;
    // Not the route's stairs / lift: you changed floor somewhere else.
    final place = _geo.placeAt(_f.s);
    if (!place.indoor || _nearSameFloorStairs()) return;
    _floorOffset += n;
    _mismatch = _floorOffset == 0 ? null : place.floor + _floorOffset;
    if (_mismatch != null) _notice = null;
  }

  /// The route climbs a staircase that stays on the same floor (e.g. a
  /// spiral stair to an attic) close to here: climbing there is expected.
  bool _nearSameFloorStairs() {
    final steps = _route.steps;
    if (_geo.stepAlong.length != steps.length) return false;
    for (var k = 0; k + 1 < steps.length; k++) {
      if (steps[k].type != 'stairs' || steps[k + 1].floor != steps[k].floor) continue;
      final at = _geo.stepAlong[k];
      if (at >= _f.s - 15 && at <= _f.s + GuideTuning.rideNearMetres) return true;
    }
    return false;
  }
}
