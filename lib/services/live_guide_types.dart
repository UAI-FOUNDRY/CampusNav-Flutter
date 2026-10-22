part of 'live_guide.dart';

// What live guidance hands the screen.

/// What is moving you along the route right now (for the status line).
enum GuideMode {
  starting, // waiting for the first sensor data / GPS fix
  gps, // outside: GPS (with your steps between fixes)
  steps, // inside, or GPS too rough: your steps and turns move you
  manual, // no step sensor: tap Next as you go
  floorChange, // at the stairs / lift: waiting for the new floor
  paused, // auto-follow turned off
  simulated, // "Simulate walk" (testing at a desk)
}

/// The stairs / lift ride you have reached: shown as the floor card until
/// the new floor is confirmed (by the barometer, a scanned sign, or you).
class FloorWait {
  final int from;
  final int to;
  final String via; // "stairs" or "lift"

  /// Barometer: how much of the climb is done (0..1), null before it starts
  /// or without a barometer.
  final double? progress;

  /// The phone has a barometer, so the card will close by itself.
  final bool automatic;

  const FloorWait({
    required this.from,
    required this.to,
    required this.via,
    this.progress,
    this.automatic = false,
  });

  bool get up => to > from;
}

/// Where to draw you, every frame.
class LivePose {
  /// Metres along the route (line metres).
  final double along;
  final GeoPoint geo;
  final bool indoor;
  final int floor;

  /// Floor-plan pixels (indoor).
  final MapPoint? plan;

  /// Direction of the route here (compass degrees) and on the floor plan
  /// (radians clockwise from up).
  final double bearing;
  final double? planAngle;

  /// Add to a compass direction (radians) to get it on the floor plan.
  final double? planNorth;

  /// Which way the phone points (compass degrees), null when unknown.
  final double? heading;

  /// How sure the position is (metres), for the halo.
  final double accuracy;

  /// GPS says you are off the path: [geo] is the raw GPS position.
  final bool offRoute;

  const LivePose({
    required this.along,
    required this.geo,
    required this.indoor,
    required this.floor,
    required this.bearing,
    required this.accuracy,
    this.plan,
    this.planAngle,
    this.planNorth,
    this.heading,
    this.offRoute = false,
  });

  /// Which way the phone points on the floor plan (radians clockwise from
  /// the top of the picture), or null.
  double? get planFacing {
    final h = heading, n = planNorth;
    if (h == null || n == null) return null;
    return h * math.pi / 180 + n;
  }
}

/// Air pressure over the last minute and a half, to see climbs.
class PressureTrack {
  double? p;
  final ListQueue<(double, double)> _hist = ListQueue<(double, double)>(); // (t, hPa)

  void add(double smoothed, double t) {
    p = smoothed;
    _hist.addLast((t, smoothed));
    while (_hist.isNotEmpty && t - _hist.first.$1 > 90) {
      _hist.removeFirst();
    }
  }

  /// The newest reading that is at least [secs] old.
  double? ago(double t, double secs) {
    double? best;
    for (final (tq, q) in _hist) {
      if (t - tq >= secs) {
        best = q;
      } else {
        break;
      }
    }
    return best;
  }

  void clear() {
    _hist.clear();
    p = null;
  }
}
