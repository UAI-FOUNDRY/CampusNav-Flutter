/// Every number worth tuning in live guidance, in one place.
///
/// Values were tuned in simulation on the real campus routes (see the tests
/// in test/live_guidance_test.dart) and on walks round the campus. If
/// something feels off on a walk, change it here and nowhere else. Each
/// value says what it does and which way to move it.
abstract final class GuideTuning {
  // ----------------------------------------------------------- walking

  /// Step length (m) before the app has learned yours. Learned from GPS
  /// outside (speed / cadence) and from corners inside, then remembered.
  static const double defaultStepLength = 0.72;

  /// Limits for the learned step length (m).
  static const double minStepLength = 0.45;
  static const double maxStepLength = 1.0;

  /// Walking speed (m/s) of "Simulate walk".
  static const double simulateSpeed = 1.3;

  // --------------------------------------------------------------- GPS

  /// GPS fixes less accurate than this (m) are ignored outside / inside.
  static const double maxFixAccuracyOutside = 25.0;
  static const double maxFixAccuracyInside = 8.0;

  /// A fix this far (m) from the path (or 1.2 x its accuracy, if more)
  /// counts as off the path ...
  static const double offRouteMetres = 25.0;

  /// ... and this many in a row ask for a new route.
  static const int offRouteFixes = 3;

  /// Fixes that keep disagreeing the same way: after this many, GPS is
  /// trusted again (the estimate was wrong).
  static const int trustGpsAfterRejects = 5;

  /// At most one new route this often.
  static const Duration rerouteCooldown = Duration(seconds: 15);

  // ----------------------------------------------------------- arrival

  /// Arrived: standing still (2 s without a step) within this many metres
  /// of the destination ...
  static const double arriveWhenStoppedWithin = 8.0;

  /// ... or walking to within this many metres of it.
  static const double arriveWithin = 3.0;

  // ----------------------------------------------------------- corners

  /// Seconds without turning before a turn is matched to a corner.
  static const double turnSettleSeconds = 2.0;

  /// Turns smaller than this (degrees) are not corners.
  static const double minCornerTurn = 45.0;

  /// A turn matches a corner of the route within this many degrees.
  static const double cornerAngleTolerance = 60.0;

  // ------------------------------------------------------------ floors

  /// Air pressure change (hPa within 5 s) that means climbing ...
  static const double climbHpa = 0.06;

  /// ... change (hPa within 3 s) that means not any more ...
  static const double calmHpa = 0.025;

  /// ... held for this many seconds: the climb is over.
  static const double calmHoldSeconds = 1.0;

  /// A climb this close (m) to the route's stairs / lift is that ride.
  static const double rideNearMetres = 40.0;

  /// Steps a floor of stairs before the app has learned your stairs
  /// (phones without a barometer), and the limits for the learned value.
  static const double defaultStairStepsPerFloor = 24;
  static const double minStairStepsPerFloor = 14;
  static const double maxStairStepsPerFloor = 40;

  // -------------------------------------------------------- map camera

  /// Seconds the outdoor map takes to turn to a new direction.
  static const double headingEaseSeconds = 0.45;

  /// The map turns towards the path this many metres ahead (it starts to
  /// turn just before a corner).
  static const double headingLookAheadMetres = 15.0;

  /// Heading-up: you sit this fraction of the map's height below its
  /// middle, so more of the way ahead shows.
  static const double personBelowCentre = 0.22;

  /// Zoom while following you outside.
  static const double followZoom = 18.5;
}
