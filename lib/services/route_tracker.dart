import 'dart:math' as math;

import '../models/route.dart';

/// Where a GPS fix falls on the outdoor route line.
class RouteFix {
  final GeoPoint point; // the fix moved onto the line
  final double along; // metres from the start of the line
  final double off; // metres between the fix and the line

  const RouteFix(this.point, this.along, this.off);
}

/// The outdoor part of a route, measured in metres, for live GPS guidance:
/// snaps fixes onto the line (so the person icon stays on the path), knows
/// how far along each step starts, and how far off the path you are.
///
/// Campus-sized distances, so a flat local projection is accurate enough.
class RouteGeometry {
  final List<GeoPoint> line;
  final List<double> _x = [];
  final List<double> _y = [];
  final List<double> _cum = [0];
  late final double _lat0;
  late final double _lng0;
  late final double _kx; // metres per degree of longitude here
  static const double _ky = 110574; // metres per degree of latitude

  /// For each route step: metres along the line where it starts, or null for
  /// indoor steps / steps without a position.
  final List<double?> stepAlong = [];

  RouteGeometry(this.line, List<RouteStep> steps) {
    _lat0 = line.first.lat;
    _lng0 = line.first.lng;
    _kx = 111320 * math.cos(_lat0 * math.pi / 180);
    for (final p in line) {
      _x.add((p.lng - _lng0) * _kx);
      _y.add((p.lat - _lat0) * _ky);
    }
    for (var i = 1; i < line.length; i++) {
      _cum.add(_cum.last + math.sqrt(math.pow(_x[i] - _x[i - 1], 2) + math.pow(_y[i] - _y[i - 1], 2)));
    }
    // Steps come in order along the line, so each is looked for only past
    // the previous one (a path that doubles back cannot confuse it).
    var after = 0.0;
    for (final s in steps) {
      final outdoor = s.space != 'indoor' && s.lat != null && s.lng != null;
      if (!outdoor) {
        stepAlong.add(null);
        continue;
      }
      final along = project(s.lat!, s.lng!, minAlong: after).along;
      stepAlong.add(along);
      after = along;
    }
  }

  /// Total length of the outdoor line in metres.
  double get length => _cum.last;

  /// The nearest point on the line to (lat, lng), only looking at the line
  /// from [minAlong] metres on.
  RouteFix project(double lat, double lng, {double minAlong = 0}) {
    final px = (lng - _lng0) * _kx;
    final py = (lat - _lat0) * _ky;
    if (line.length == 1) {
      return RouteFix(line.first, 0, math.sqrt(px * px + py * py));
    }
    var bestD = double.infinity;
    var bestAlong = 0.0;
    var bestX = _x.first;
    var bestY = _y.first;
    for (var i = 1; i < line.length; i++) {
      if (_cum[i] < minAlong) continue;
      final ax = _x[i - 1], ay = _y[i - 1];
      final dx = _x[i] - ax, dy = _y[i] - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
      final tMin = len2 == 0 ? 0.0 : ((minAlong - _cum[i - 1]) / math.sqrt(len2)).clamp(0.0, 1.0).toDouble();
      t = t.clamp(tMin, 1.0).toDouble();
      final cx = ax + t * dx, cy = ay + t * dy;
      final d = math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
      if (d < bestD) {
        bestD = d;
        bestAlong = _cum[i - 1] + t * math.sqrt(len2);
        bestX = cx;
        bestY = cy;
      }
    }
    if (bestD == double.infinity) {
      // Asked for a point past the end: the end of the line.
      final dx = px - _x.last, dy = py - _y.last;
      return RouteFix(line.last, length, math.sqrt(dx * dx + dy * dy));
    }
    return RouteFix(
      GeoPoint(_lat0 + bestY / _ky, _lng0 + bestX / _kx),
      bestAlong,
      bestD,
    );
  }
}
