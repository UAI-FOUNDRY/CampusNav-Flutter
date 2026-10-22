part of 'live_guide.dart';

// Where along the route you are: GPS fixes matched to the path, the steps
// you took, and turns matched to the route's corners.
//
// An extension of LiveGuide (same library), so it reads and writes the
// guide's state directly. The tuning values are in GuideTuning.
extension _GuidePosition on LiveGuide {
  /// Steps in [from, to) seconds.
  int _stepsBetween(double from, double to) {
    var n = 0;
    for (final s in _stepTimes) {
      if (s >= from && s < to) n++;
    }
    return n;
  }

  int _stepsSince(double from) {
    var n = 0;
    for (final s in _stepTimes) {
      if (s >= from) n++;
    }
    return n;
  }

  /// Steps a second over the last 4 s, or null.
  double? _cadence(double t) {
    final recent = [for (final s in _stepTimes) if (t - s <= 4.0) s];
    if (recent.length < 5) return null;
    final span = recent.last - recent.first;
    return span > 0 ? (recent.length - 1) / span : null;
  }

  /// The compass says you face away from the route (inside, phone in hand).
  bool _walkingAway(double t) {
    final h = _motion.heading, at = _motion.headingAt;
    if (h == null || at == null || t - at > 1.0 || !_motion.inHand) return false;
    if (!_geo.placeAt(_f.s).indoor) return false; // outside GPS sorts it out
    return RouteGeometry.wrap180(h - _geo.bearingAt(_f.s)).abs() > 135;
  }

  void _gpsFix(Position p) {
    final t = SensorClock.now();
    _lastFix = p;
    if (!_running || _paused || _simulating) return;
    _predict(t);
    final acc = p.accuracy;
    final place = _geo.placeAt(_f.s);
    _outsideReference(p, place.indoor, t);
    final maxAcc = place.indoor ? GuideTuning.maxFixAccuracyInside : GuideTuning.maxFixAccuracyOutside;
    if (acc > maxAcc || _waiting) return;

    final fix = _geo.project(
      p.latitude,
      p.longitude,
      minAlong: _f.s - 30,
      maxAlong: _f.s + math.max(60.0, 2 * acc),
      keys: {place.indoor ? 'f${place.floor}' : 'out'},
      hint: _f.s,
    );
    if (fix == null) return;
    if (fix.off > math.max(GuideTuning.offRouteMetres, acc * 1.2)) {
      _offFixes++;
      if (!place.indoor) {
        _offPos = GeoPoint(p.latitude, p.longitude);
        if (_offFixes >= GuideTuning.offRouteFixes && _rerouteFrom == null) {
          _rerouteFrom = p;
          _changed();
        }
      }
      return;
    }
    _offFixes = 0;
    _offPos = null;

    final sigma = math.max(2.5, acc / 1.5) * 1.3;
    final r = sigma * sigma;
    final y = fix.along - _f.s;
    final gate = (place.indoor ? 2.0 : 3.0) * _f.innovationSigma(r);
    if (y.abs() > gate) {
      final sign = y > 0 ? 1 : -1;
      _rejects = sign == _rejectSign ? _rejects + 1 : 1;
      _rejectSign = sign;
      if (_rejects >= GuideTuning.trustGpsAfterRejects && acc <= 15 && !place.indoor) {
        // GPS keeps disagreeing the same way: we were wrong, trust it again.
        _f.reset(fix.along, sigma: sigma);
        _rejects = 0;
        _clamp();
      }
      return;
    }
    _rejects = 0;
    _f.updatePosition(fix.along, r);
    _gpsGoodAt = t;

    // GPS speed along the path (Doppler: accurate outside while moving).
    if (!place.indoor && acc <= 20) {
      if (p.speed >= 0.5 && p.heading >= 0) {
        final rb = _geo.bearingAt(_f.s);
        final along = p.speed * math.cos(RouteGeometry.wrap180(p.heading - rb) * math.pi / 180);
        _f.updateVelocity(along, 0.25 * 0.25);
        if (p.speed >= 0.8) _gpsSpeedAt = t;
        // Step length = speed / cadence while walking steadily with a sharp fix.
        final cad = _cadence(t);
        if (acc <= 12 && p.speed > 0.8 && cad != null && cad >= 1.2 && cad <= 2.6) {
          final est = p.speed / cad;
          if (est >= 0.4 && est <= 1.1) _stepLength = 0.85 * _stepLength + 0.15 * est;
        }
      } else if (p.speed >= 0 && p.speed < 0.3) {
        _f.updateVelocity(0, 0.3 * 0.3);
      }
    }
    _clamp();
  }

  /// Once the turning has settled, decide what the turn segments were and,
  /// if they were the route's corners, correct the position.
  void _checkTurns(double t) {
    if (_segs.isEmpty || _motion.turns.turning || t - _segs.last.$3 < GuideTuning.turnSettleSeconds) return;
    final segs = List<(double, double, double)>.of(_segs);
    _segs.clear();
    final lastStep = _lastStepT;
    final recentlyWalking = lastStep != null && t - lastStep < 4.0;
    if (_waiting || _climbNearRide || !recentlyWalking) return;
    _predict(t);

    // Where we thought we were at time ts: now minus the steps since.
    (double, double) posAt(double ts) {
      final back = _stepLength * _stepsSince(ts);
      return (_f.s - back, back);
    }

    final hold = _holdRide;
    List<RouteCorner> candidates(double angle, double at, double window) => [
          for (final c in _geo.corners)
            if ((c.turn > 0) == (angle > 0) &&
                (c.turn.abs() - angle.abs()).abs() <= GuideTuning.cornerAngleTolerance &&
                (hold == null || c.along <= hold.from + 0.5) &&
                (c.along - at).abs() <= window)
              c,
        ];

    final big = [for (final s in segs) if (s.$1.abs() >= GuideTuning.minCornerTurn) s];
    final lastEnd = segs.last.$3;
    final (atLast, _) = posAt(lastEnd);
    final walked = (atLast - _anchorS).abs();
    final window = math.min(25.0, 8.0 + 0.10 * walked);
    var net = 0.0;
    for (final s in segs) {
      net += s.$1;
    }

    // Match the turns in [seq] to corners in order.
    ({double cost, RouteCorner corner, double end})? chainFor(List<(double, double, double)> seq) {
      final (at0, _) = posAt(seq.first.$3);
      ({double cost, RouteCorner corner, double end})? found;
      for (final c0 in candidates(seq.first.$1, at0, window)) {
        final chain = <RouteCorner>[c0];
        var ok = true;
        var cost = (c0.along - at0).abs();
        for (var k = 1; k < seq.length; k++) {
          final gap = _stepLength * _stepsBetween(seq[k - 1].$3, seq[k].$3);
          final prev = chain.last;
          final next = [
            for (final c in candidates(seq[k].$1, prev.along + gap, 4.0))
              if (c.along > prev.along + 0.5) c,
          ];
          if (next.isEmpty) {
            ok = false;
            break;
          }
          next.sort((a, b) =>
              (a.along - prev.along - gap).abs().compareTo((b.along - prev.along - gap).abs()));
          final c = next.first;
          cost += (c.along - prev.along - gap).abs();
          chain.add(c);
        }
        if (ok && (found == null || cost < found.cost)) {
          found = (cost: cost, corner: chain.last, end: seq.last.$3);
        }
      }
      return found;
    }

    // 1: every big turn is a corner, in order (one corner, or an S-bend).
    var best = big.isEmpty ? null : chainFor(big);
    // The phone twisted and back: nothing happened.
    if (best == null && segs.length >= 2 && net.abs() < 30) return;
    // 2: the net change is one corner (taken while twisting the phone).
    if (best == null && net.abs() >= GuideTuning.minCornerTurn) {
      final cs = candidates(net, atLast, window);
      if (cs.isNotEmpty) {
        cs.sort((a, b) => (a.along - atLast).abs().compareTo((b.along - atLast).abs()));
        best = (cost: (cs.first.along - atLast).abs(), corner: cs.first, end: lastEnd);
      }
    }
    // 3: the first turns were corners, the rest something else.
    var k = big.length - 1;
    while (best == null && k >= 1) {
      best = chainFor(big.sublist(0, k));
      k--;
    }
    if (best == null) return;

    final corner = best.corner;
    final (atTurn, since) = posAt(best.end);
    final z = corner.along + 0.8 + since;
    final walkedSince = atTurn - _anchorS;
    final err = (corner.along + 0.8) - atTurn;
    if (walkedSince >= 12 && err.abs() <= 6 && _geo.placeAt(_f.s).indoor) {
      // Inside, the corner says how long your steps really are.
      final ratio = ((walkedSince + err) / walkedSince).clamp(0.85, 1.15).toDouble();
      _stepLength = (_stepLength * math.sqrt(ratio))
          .clamp(GuideTuning.minStepLength, GuideTuning.maxStepLength)
          .toDouble();
    }
    _f.updatePosition(z, 1.5 * 1.5);
    _anchorS = corner.along;
    _clamp();
  }
}
