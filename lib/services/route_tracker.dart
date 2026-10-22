import 'dart:math' as math;

import '../models/route.dart';

/// Where a GPS fix falls on the route line.
class RouteFix {
  final GeoPoint point; // the fix moved onto the line
  final double along; // metres from the start of the route
  final double off; // metres between the fix and the line

  const RouteFix(this.point, this.along, this.off);
}

/// A stair or lift ride inside the route: the line does not move on the map
/// here, it changes floor. Live guidance waits at [from] until the new floor
/// is confirmed (by the barometer or by you).
class FloorRide {
  final double from; // metres along the route where the ride starts
  final double to; // ... and where the new floor's line starts
  final int fromFloor;
  final int toFloor;
  final String via; // "stairs" or "lift"

  const FloorRide(this.from, this.to, this.fromFloor, this.toFloor, this.via);

  bool get up => toFloor > fromFloor;
  int get floors => toFloor - fromFloor;
}

/// A corner of the route: where the path turns by [turn] degrees
/// (positive = right). Live guidance matches the turns your phone feels
/// (gyroscope) to these, which corrects the step count inside buildings.
class RouteCorner {
  final double along;
  final double turn;
  final bool indoor;

  const RouteCorner(this.along, this.turn, this.indoor);
}

/// One point of the route, somewhere along it.
class RouteSpot {
  final GeoPoint geo;
  final bool indoor;
  final int floor; // 0 outdoors

  /// Floor-plan pixels (indoor).
  final MapPoint? plan;

  /// Compass direction of the route here (0 = north, 90 = east).
  final double bearing;

  /// Direction of the route on the floor plan: radians clockwise from "up".
  final double? planAngle;

  const RouteSpot({
    required this.geo,
    required this.indoor,
    required this.floor,
    required this.bearing,
    this.plan,
    this.planAngle,
  });
}

class _Pt {
  final double lat, lng, x, y; // x/y: flat metres from the route start
  final bool indoor;
  final int floor;
  final double? px, py; // floor-plan pixels
  final double along;

  const _Pt(this.lat, this.lng, this.x, this.y, this.indoor, this.floor, this.px, this.py, this.along);

  String get key => indoor ? 'f$floor' : 'out';
}

/// The WHOLE route (the outdoor line, then one line per floor, joined by the
/// stair/lift rides) measured in metres, for live guidance.
///
/// Every point has GPS: outdoor points directly, indoor points through the
/// building's GPS tie-in (the backend's georef). So the same line serves GPS
/// outside, step counting inside, and the floor plan's x/y.
///
/// Campus-sized distances, so a flat local projection is accurate enough.
class RouteGeometry {
  final List<_Pt> _pts = [];
  final List<FloorRide> rides = [];

  /// For each route step: metres along the route where it starts.
  final List<double> stepAlong = [];

  /// Where the route turns by 45 degrees or more.
  final List<RouteCorner> corners = [];

  /// Backend metres per line metre (about 1). The backend counts stair rides
  /// and measured corridors; multiply line metres by this for display.
  double scale = 1;

  double _lat0 = 0;
  double _lng0 = 0;
  double _kx = 1; // metres per degree of longitude here
  static const double _ky = 110574; // metres per degree of latitude

  RouteGeometry(NavigationRoute route) {
    // The points in walking order.
    final raw = <({double lat, double lng, bool indoor, int floor, double? px, double? py})>[];
    for (final leg in route.legs) {
      if (leg.isIndoor) {
        for (final p in leg.points) {
          final lat = p.lat, lng = p.lng;
          if (lat == null || lng == null) continue; // older backend: no GPS indoors
          raw.add((lat: lat, lng: lng, indoor: true, floor: leg.floor, px: p.x, py: p.y));
        }
      } else {
        for (final p in leg.polyline) {
          raw.add((lat: p.lat, lng: p.lng, indoor: false, floor: 0, px: null, py: null));
        }
      }
    }
    if (raw.isEmpty) return;
    _lat0 = raw.first.lat;
    _lng0 = raw.first.lng;
    _kx = 111320 * math.cos(_lat0 * math.pi / 180);

    // Lift/stair rides in order, with their real length from the route.
    // (A spiral stair inside one floor is a "stairs" step too, but no ride.)
    final steps = route.steps;
    final rideInfo = <({double length, String via})>[
      for (var k = 0; k + 1 < steps.length; k++)
        if (steps[k].isFloorChange && steps[k + 1].floor != steps[k].floor)
          (length: steps[k].distance ?? 10.0, via: steps[k].type),
    ];
    var ride = 0;

    for (final r in raw) {
      final x = (r.lng - _lng0) * _kx, y = (r.lat - _lat0) * _ky;
      var along = 0.0;
      if (_pts.isNotEmpty) {
        final p = _pts.last;
        var d = math.sqrt((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y));
        if (p.indoor && r.indoor && p.floor != r.floor) {
          final info = ride < rideInfo.length ? rideInfo[ride++] : null;
          final len = info?.length ?? 8.0 * (r.floor - p.floor).abs();
          d = math.max(d, math.max(1.0, len));
          rides.add(FloorRide(p.along, p.along + d, p.floor, r.floor, info?.via ?? 'stairs'));
        } else if (d < 0.05 && p.indoor == r.indoor) {
          continue; // the same point twice, where two legs meet
        }
        along = p.along + d;
      }
      _pts.add(_Pt(r.lat, r.lng, x, y, r.indoor, r.floor, r.px, r.py, along));
    }

    if (length > 0 && route.distance > 0) {
      scale = (route.distance / length).clamp(0.6, 1.6).toDouble();
    }

    // Where each step starts: its dot matched onto the line (same floor),
    // never before the previous step.
    for (var k = 0; k < steps.length; k++) {
      if (k == 0) {
        stepAlong.add(0);
        continue;
      }
      final prev = stepAlong[k - 1];
      final st = steps[k];
      if (k == steps.length - 1 && st.type == 'arrive') {
        stepAlong.add(length);
        continue;
      }
      var at = prev + (steps[k - 1].distance ?? 0) / scale; // fallback: walk the distances
      final lat = st.lat, lng = st.lng;
      if (lat != null && lng != null) {
        final key = st.space == 'indoor' ? 'f${st.floor ?? 0}' : 'out';
        final fix = project(lat, lng, minAlong: prev - 0.5, keys: {key}, hint: prev);
        if (fix != null && fix.off < 25) at = fix.along;
      }
      stepAlong.add(math.min(length, math.max(prev, at)));
    }

    corners.addAll(_findCorners());
  }

  /// Total length in metres (line metres; x [scale] for the route's metres).
  double get length => _pts.isEmpty ? 0.0 : _pts.last.along;

  /// False when the backend sent no positions to follow.
  bool get usable => _pts.length >= 2 && length > 0;

  bool _isRide(int i) {
    final a = _pts[i], b = _pts[i + 1];
    return a.indoor && b.indoor && a.floor != b.floor;
  }

  /// Segment i (points i -> i + 1) holding [along].
  int _segment(double along) {
    var lo = 0, hi = _pts.length - 2;
    if (hi < 0) return 0;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_pts[mid].along <= along) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  ({double lat, double lng}) _geoAt(double along) {
    final i = _segment(along);
    final a = _pts[i], b = _pts[i + 1];
    final len = b.along - a.along;
    final t = len <= 0 ? 0.0 : ((along - a.along) / len).clamp(0.0, 1.0).toDouble();
    return (lat: a.lat + (b.lat - a.lat) * t, lng: a.lng + (b.lng - a.lng) * t);
  }

  /// Flat x/y (metres east/north of the route start) at [along].
  ({double x, double y}) _xyAt(double along) {
    final i = _segment(along);
    final a = _pts[i], b = _pts[i + 1];
    final len = b.along - a.along;
    final t = len <= 0 ? 0.0 : ((along - a.along) / len).clamp(0.0, 1.0).toDouble();
    return (x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t);
  }

  /// Inside or outside, and which floor, at [along] (cheap).
  ({bool indoor, int floor}) placeAt(double along) {
    if (_pts.isEmpty) return (indoor: false, floor: 0);
    if (_pts.length == 1) return (indoor: _pts.first.indoor, floor: _pts.first.floor);
    along = along.clamp(0.0, length).toDouble();
    final i = _segment(along);
    final a = _pts[i], b = _pts[i + 1];
    final len = b.along - a.along;
    final t = len <= 0 ? 0.0 : (along - a.along) / len;
    final near = t < 0.5 ? a : b;
    return (indoor: near.indoor, floor: near.floor);
  }

  /// Where the route is [along] metres from the start.
  RouteSpot at(double along) {
    if (_pts.isEmpty) {
      return const RouteSpot(geo: GeoPoint(0, 0), indoor: false, floor: 0, bearing: 0);
    }
    if (_pts.length == 1) {
      final p = _pts.first;
      final px = p.px, py = p.py;
      return RouteSpot(
        geo: GeoPoint(p.lat, p.lng),
        indoor: p.indoor,
        floor: p.floor,
        bearing: 0,
        plan: px == null || py == null ? null : MapPoint(px, py),
      );
    }
    along = along.clamp(0.0, length).toDouble();
    final i = _segment(along);
    final a = _pts[i], b = _pts[i + 1];
    final len = b.along - a.along;
    final t = len <= 0 ? 0.0 : ((along - a.along) / len).clamp(0.0, 1.0).toDouble();
    final near = t < 0.5 ? a : b;

    MapPoint? plan;
    final apx = a.px, apy = a.py, bpx = b.px, bpy = b.py;
    if (a.indoor && b.indoor && a.floor == b.floor && apx != null && apy != null && bpx != null && bpy != null) {
      plan = MapPoint(apx + (bpx - apx) * t, apy + (bpy - apy) * t);
    } else {
      // A doorway or a ride: stand on the nearer indoor end.
      final end = near.indoor ? near : (a.indoor ? a : b);
      final ex = end.px, ey = end.py;
      if (ex != null && ey != null) plan = MapPoint(ex, ey);
    }
    return RouteSpot(
      geo: GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t),
      indoor: near.indoor,
      floor: near.floor,
      plan: plan,
      bearing: bearingAt(along),
      planAngle: planAngleAt(along),
    );
  }

  /// Compass direction of the route from [along], looking a few metres
  /// ahead so the arrow turns smoothly at corners.
  double bearingAt(double along, {double look = 5}) {
    if (_pts.length < 2) return 0;
    along = along.clamp(0.0, length).toDouble();
    final i = _segment(along);
    for (var k = i; k < _pts.length - 1; k++) {
      if (_isRide(k)) continue;
      final a = _pts[k], b = _pts[k + 1];
      if (_dist(a.x, a.y, b.x, b.y) < 0.4) continue;
      final from = k == i ? _geoAt(along) : (lat: a.lat, lng: a.lng);
      final to = _geoAt(math.min(length, math.max(along + look, a.along + 0.01)));
      final same = (from.lat - to.lat).abs() < 1e-7 && (from.lng - to.lng).abs() < 1e-7;
      return same ? compass(a.lat, a.lng, b.lat, b.lng) : compass(from.lat, from.lng, to.lat, to.lng);
    }
    for (var k = _pts.length - 2; k >= 0; k--) {
      final a = _pts[k], b = _pts[k + 1];
      if (!_isRide(k) && _dist(a.x, a.y, b.x, b.y) >= 0.4) return compass(a.lat, a.lng, b.lat, b.lng);
    }
    return 0;
  }

  /// Direction of the route on the floor plan (radians clockwise from up),
  /// null outdoors.
  double? planAngleAt(double along) {
    if (_pts.length < 2) return null;
    final i = _segment(along.clamp(0.0, length).toDouble());
    bool sameFloor(_Pt a, _Pt b) =>
        a.indoor && b.indoor && a.floor == b.floor && a.px != null && b.px != null;
    for (var k = i; k < _pts.length - 1; k++) {
      final a = _pts[k], b = _pts[k + 1];
      if (!sameFloor(a, b)) {
        if (k == i) continue;
        break;
      }
      final dx = b.px! - a.px!, dy = b.py! - a.py!;
      if (dx * dx + dy * dy >= 1) return math.atan2(dx, -dy);
    }
    for (var k = math.min(i, _pts.length - 2); k >= 0; k--) {
      final a = _pts[k], b = _pts[k + 1];
      if (!sameFloor(a, b)) break;
      final dx = b.px! - a.px!, dy = b.py! - a.py!;
      if (dx * dx + dy * dy >= 1) return math.atan2(dx, -dy);
    }
    return null;
  }

  /// How the floor plan is turned against the compass at [along]: add it to
  /// a compass direction (radians) to get the direction on the plan
  /// (radians clockwise from the top of the picture). Null outdoors.
  double? planNorthAt(double along) {
    if (_pts.length < 2) return null;
    final floor = placeAt(along);
    if (!floor.indoor) return null;
    final i = _segment(along.clamp(0.0, length).toDouble());
    // The nearest straight piece on this floor with both pixels and metres.
    for (var d = 0; d < _pts.length; d++) {
      for (final k in [i + d, i - d]) {
        if (k < 0 || k >= _pts.length - 1) continue;
        final a = _pts[k], b = _pts[k + 1];
        if (!a.indoor || !b.indoor || a.floor != floor.floor || b.floor != floor.floor) continue;
        final apx = a.px, apy = a.py, bpx = b.px, bpy = b.py;
        if (apx == null || apy == null || bpx == null || bpy == null) continue;
        final dx = bpx - apx, dy = bpy - apy;
        final mx = b.x - a.x, my = b.y - a.y;
        if (dx * dx + dy * dy < 25 || mx * mx + my * my < 1) continue;
        final onPlan = math.atan2(dx, -dy); // clockwise from up
        final onEarth = math.atan2(mx, my); // clockwise from north
        return onPlan - onEarth;
      }
    }
    return null;
  }

  /// The nearest point on the line to (lat, lng), only between [minAlong] and
  /// [maxAlong], only on lines with one of [keys] ("out", "f0", "f1" ...; a
  /// doorway counts for both its ends). Rides are never matched. [hint]
  /// (where you were) breaks ties between parallel corridors.
  RouteFix? project(
    double lat,
    double lng, {
    double minAlong = double.negativeInfinity,
    double maxAlong = double.infinity,
    Set<String>? keys,
    double? hint,
  }) {
    if (_pts.length < 2) return null;
    final px = (lng - _lng0) * _kx, py = (lat - _lat0) * _ky;
    RouteFix? best;
    var bestCost = double.infinity;
    for (var i = 0; i < _pts.length - 1; i++) {
      final a = _pts[i], b = _pts[i + 1];
      if (b.along < minAlong || a.along > maxAlong || _isRide(i)) continue;
      if (keys != null && !keys.contains(a.key) && !keys.contains(b.key)) continue;
      final dx = b.x - a.x, dy = b.y - a.y;
      final len2 = dx * dx + dy * dy;
      final span = b.along - a.along;
      var t = len2 == 0 ? 0.0 : (((px - a.x) * dx + (py - a.y) * dy) / len2).clamp(0.0, 1.0).toDouble();
      // Keep the answer inside [minAlong, maxAlong].
      if (span > 0) {
        final tMin = ((minAlong - a.along) / span).clamp(0.0, 1.0).toDouble();
        final tMax = ((maxAlong - a.along) / span).clamp(0.0, 1.0).toDouble();
        t = t.clamp(tMin, tMax).toDouble();
      }
      final cx = a.x + t * dx, cy = a.y + t * dy;
      final d = _dist(px, py, cx, cy);
      final along = a.along + t * span;
      final cost = d + (hint == null ? 0.0 : 0.05 * (along - hint).abs());
      if (cost < bestCost) {
        bestCost = cost;
        best = RouteFix(GeoPoint(_lat0 + cy / _ky, _lng0 + cx / _kx), along, d);
      }
    }
    return best;
  }

  /// The next stair/lift ride that ends after [along] (the one to wait at).
  FloorRide? nextRide(double along) {
    for (final r in rides) {
      if (r.to > along + 0.01) return r;
    }
    return null;
  }

  /// How many floor changes lie before [along] (which stretch of the route
  /// between rides it is in).
  int runAt(double along) {
    var n = 0;
    for (final r in rides) {
      if (along >= r.to - 0.005) n++;
    }
    return n;
  }

  /// "out" or "f<floor>" at [along]: the lines GPS fixes may be matched to.
  String keyAt(double along) {
    final p = placeAt(along);
    return p.indoor ? 'f${p.floor}' : 'out';
  }

  /// The step that starts at or before [along] (the one being walked).
  int stepAt(double along) {
    var k = 0;
    for (var i = 0; i < stepAlong.length; i++) {
      if (stepAlong[i] <= along + 0.01) k = i;
    }
    return k;
  }

  /// Where the route turns by 45 degrees or more (signed, + right), within
  /// each stretch between floor changes. Bends drawn as several short
  /// pieces count as one corner.
  List<RouteCorner> _findCorners() {
    if (_pts.length < 3) return const [];
    final runs = <(int, int)>[];
    var start = 0;
    for (var i = 0; i < _pts.length - 1; i++) {
      if (_isRide(i)) {
        runs.add((start, i));
        start = i + 1;
      }
    }
    runs.add((start, _pts.length - 1));

    final cand = <({double along, double turn, bool indoor})>[];
    for (final (i0, i1) in runs) {
      final a0 = _pts[i0].along, a1 = _pts[i1].along;
      for (var i = i0 + 1; i < i1; i++) {
        final al = _pts[i].along;
        final before = _xyAt(math.max(a0, al - 4.0));
        final after = _xyAt(math.min(a1, al + 4.0));
        final xi = _pts[i].x, yi = _pts[i].y;
        if (_dist(xi, yi, before.x, before.y) < 1.0 || _dist(after.x, after.y, xi, yi) < 1.0) continue;
        final bIn = math.atan2(xi - before.x, yi - before.y) * 180 / math.pi;
        final bOut = math.atan2(after.x - xi, after.y - yi) * 180 / math.pi;
        final turn = wrap180(bOut - bIn);
        if (turn.abs() >= 30) cand.add((along: al, turn: turn, indoor: _pts[i].indoor));
      }
    }
    final merged = <({double along, double turn, bool indoor})>[];
    for (final c in cand) {
      if (merged.isNotEmpty) {
        final m = merged.last;
        if (c.along - m.along < 3.0 && (c.turn > 0) == (m.turn > 0)) {
          final w0 = m.turn.abs(), w1 = c.turn.abs();
          merged[merged.length - 1] = (
            along: (m.along * w0 + c.along * w1) / (w0 + w1),
            turn: (m.turn + c.turn).clamp(-180.0, 180.0).toDouble(),
            indoor: m.indoor || c.indoor,
          );
          continue;
        }
      }
      merged.add(c);
    }
    return [
      for (final m in merged)
        if (m.turn.abs() >= 45) RouteCorner(m.along, m.turn, m.indoor),
    ];
  }

  static double _dist(double ax, double ay, double bx, double by) =>
      math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

  /// -180..180
  static double wrap180(double a) => ((a + 540) % 360) - 180;

  /// Compass bearing 0..360 from point 1 to point 2.
  static double compass(double lat1, double lng1, double lat2, double lng2) {
    final la1 = lat1 * math.pi / 180, la2 = lat2 * math.pi / 180;
    final dLo = (lng2 - lng1) * math.pi / 180;
    final y = math.sin(dLo) * math.cos(la2);
    final x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dLo);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}
