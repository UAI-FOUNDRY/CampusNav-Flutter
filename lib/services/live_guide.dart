import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route.dart';
import '../models/start_point.dart';
import 'api_service.dart';
import 'floor_barometer.dart';
import 'location_service.dart';
import 'motion_sensors.dart';
import 'position_filter.dart';
import 'route_tracker.dart';
import 'wifi_fingerprints.dart';

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

/// Live guidance along one route, like Google Maps, inside and out.
///
/// Everything is one number: how far along the route you are. A small
/// Kalman filter ([AlongFilter]) keeps it, and every sensor feeds it what it
/// is good at:
///
///  * Steps (accelerometer) give your walking speed, so the arrow moves the
///    moment you walk, inside and out. Step length is learned (from GPS speed
///    outside, from corners inside) and remembered.
///  * GPS (outside) gives your position on the path and its speed; fixes
///    that disagree too much are ignored, a run of them re-syncs, three off
///    the path ask for a new route.
///  * Turns (gyroscope) are matched to the route's corners when you take
///    them, which corrects the distance inside buildings.
///  * Air pressure (barometer) sees you climb: at the stairs / lift the
///    floor card closes by itself when you reach the floor, and if you
///    change floor elsewhere you are told.
///  * The compass shows which way you face, for "turn around" hints.
///
/// The screen calls [frame] on every frame and draws [pose]; it listens to
/// this object for everything else (step, metres left, floor card ...).
class LiveGuide extends ChangeNotifier {
  LiveGuide({
    required NavigationRoute route,
    this.startFloorKnown = false,
    double startSigma = 3,
  })  : _route = route,
        _geo = RouteGeometry(route),
        _f = AlongFilter(sigma: startSigma);

  /// The start is a place you picked or a sign you scanned (not a GPS
  /// guess), so the floor it is on is certain: the barometer reference is
  /// set from it.
  final bool startFloorKnown;

  // Tuned in simulation on the real campus routes (see docs in the README).
  static const double defaultStepLength = 0.72;
  static const double _climbDp = 0.06; // hPa change within 5 s: climbing
  static const double _calmDp = 0.025; // hPa change within 3 s: not any more
  static const double _calmHold = 1.0; // s of calm that ends a climb
  static const double _settle = 2.0; // s without turning before deciding
  static const double _minTurn = 45.0;
  static const double _angleTol = 60.0;
  static const double _rideNear = 40.0; // m: a climb this close is the route's ride
  static const double _walkSpeed = 1.3; // m/s, simulation

  NavigationRoute _route;
  RouteGeometry _geo;
  AlongFilter _f;
  double _stepLength = defaultStepLength;

  final MotionSensors _motion = MotionSensors();
  final FloorBarometer _baro = FloorBarometer.instance;
  final PressureTrack _press = PressureTrack();
  bool _baroOn = false;
  StreamSubscription<Position>? _gpsSub;
  Timer? _ticker;
  bool _running = false;
  bool _disposed = false;
  double _startedAt = 0;
  int? _startRefFloor; // set the barometer reference at the first reading

  // steps
  double? _lastStepT;
  final ListQueue<double> _stepTimes = ListQueue<double>();
  int _awaySteps = 0; // steps in a row walking away from the route (compass)

  // GPS
  Position? _lastFix;
  LocateResult? _gpsProblem;
  double _gpsGoodAt = -1e9; // a fix was used
  double _gpsSpeedAt = -1e9; // GPS said you were moving
  double _lastOutsideRef = -1e9;
  int _rejects = 0;
  int _rejectSign = 0;
  int _offFixes = 0;
  GeoPoint? _offPos;
  Position? _rerouteFrom;

  // floors
  double _confirmedS = 0;
  double? _p0;
  double? _learnP0;
  int _learnFloors = 0;
  bool _pendingExtra = false;
  bool _climbing = false;
  double? _calmSince;
  double? _fastSince;
  double? _climbEndT;
  int _floorOffset = 0;
  int? _mismatch;
  bool? _wasIndoor;

  // Floors without a barometer: stairs counted (steps + how far you turned
  // round), lifts felt (accelerometer), the Wi-Fi floor checked (Android).
  FloorRide? _rideFor; // the ride the counts below belong to
  int _rideSteps = 0;
  double _rideYaw0 = 0;
  // The walking rhythm: on the level before the stairs, and on the stairs.
  double? _levelGap;
  final List<double> _rideGaps = [];
  double _stairSteps = 24; // steps per floor (learned)
  // After the stairs card closed at a full count: steps still climbing.
  double? _absorbLevel;
  double? _absorbStair;
  int _absorbBase = 0;
  int _absorbFloors = 0;
  int _absorbLeft = 0;
  int _absorbSteps = 0;
  int _absorbLevelRun = 0;
  // The lift: metres ridden the route's way, the pushes felt, when you
  // stepped in, the walk under way, and the times you stood still.
  double _liftRight = 0;
  int _liftPushes = 0;
  double? _liftStartAt; // a start the route's way: its time and speed
  double _liftStartSpeed = 0;
  double? _liftEnteredAt; // the end of your latest walk at the lift
  bool _liftPushInside = false; // the latest push came after that walk
  int _liftWalk = 0;
  double _liftLastStepT = -1e9;
  int _liftStills = 0;
  bool _liftStillCounted = false;
  double? _liftStillSince;
  double _liftSince = 0;
  bool _wifiBusy = false;
  double _wifiAt = -1e9;
  int? _wifiFloor;
  int _wifiAgree = 0;
  bool _rememberedArrival = false;

  // turns
  final List<(double, double, double)> _segs = []; // (angle, t0, t1)
  double _anchorS = 0;

  // display
  double _shown = 0;
  int _shownRun = 0;
  double? _lastFrame;
  int _stepIndex = 0;
  double _toNext = 0;
  double _remaining = 0;
  bool _arrived = false;
  String _signature = '';
  String? _notice;

  bool _paused = false;
  bool _simulating = false;
  double? _simWaitSince;

  /// Where to draw you; updated by [frame].
  final ValueNotifier<LivePose?> pose = ValueNotifier<LivePose?>(null);

  // ------------------------------------------------------------- outputs

  NavigationRoute get route => _route;
  RouteGeometry get geometry => _geo;
  int get stepIndex => _stepIndex;

  /// Metres to the start of the next step (counts down as you walk).
  double get metresToNext => _toNext;

  /// Metres to the destination.
  double get remaining => _remaining;
  bool get arrived => _arrived;
  bool get paused => _paused;
  bool get simulating => _simulating;
  double get stepLength => _stepLength;
  double get positionSigma => _f.sigma;
  Position? get lastFix => _lastFix;
  LocateResult? get gpsProblem => _gpsProblem;
  bool get hasStepSensor => _motion.hasAccelerometer;
  bool get hasGyroscope => _motion.hasGyroscope;
  bool get hasCompass => _motion.hasCompass;
  bool get hasBarometer => _baro.available && _baro.pressure.value != null;

  /// How the floor change at the stairs / lift is noticed:
  /// "barometer", "steps" (stairs counted), "motion" (lift felt), or null
  /// (no sensor: the button).
  String? get floorSensing {
    if (hasBarometer) return 'barometer';
    if (!_motion.hasAccelerometer) return null;
    final r = _holdRide;
    return r != null && r.via == 'lift' ? 'motion' : 'steps';
  }
  int get stepCount => _motion.stepCount;

  /// What the lift sensing feels now (for the sensor sheet).
  String get liftStatus {
    final l = _motion.lift;
    if (!_motion.hasAccelerometer) return 'No accelerometer';
    if (l.riding) {
      return 'A lift is moving ${l.direction > 0 ? 'up' : 'down'} at about '
          '${l.speed.toStringAsFixed(1)} m/s';
    }
    final n = l.starts;
    return n == 0 ? 'Still (no lift felt yet)' : 'Still ($n lift ${n == 1 ? 'start' : 'starts'} felt so far)';
  }

  /// Steps a floor of stairs (learned from your walking rhythm and taps).
  double get stairStepsPerFloor => _stairSteps;
  double? get compassHeading => _motion.heading;

  /// The barometer says you are on another floor than the route (inside).
  int? get floorMismatch => _mismatch;

  /// Set when GPS says you are off the path outside: the screen asks the
  /// server for a new route from there, then calls [replaceRoute].
  Position? get rerouteRequest => _rerouteFrom;

  /// A one-off message for a toast ("You're on floor 1"), then cleared.
  String? takeNotice() {
    final n = _notice;
    _notice = null;
    return n;
  }

  /// The floor card, while you should be taking the stairs / lift.
  FloorWait? get wait {
    final ride = _geo.nextRide(_confirmedS);
    if (ride == null || _arrived || _f.s < ride.from - 0.01) return null;
    double? progress;
    final p0 = _p0, p = _press.p;
    if (_climbing && p0 != null && p != null && ride.floors != 0) {
      progress = (_baro.floorsBetween(p0, p) / ride.floors).clamp(0.0, 1.0).toDouble();
    } else if (!hasBarometer && _rideFor == ride && ride.floors != 0) {
      if (ride.via == 'lift') {
        // Never full before the card closes: it closes when the lift stops.
        final lift = _motion.lift;
        var metres = _liftRight;
        if (lift.riding && lift.direction * ride.floors > 0) {
          metres += lift.heightSoFar(SensorClock.now()).abs();
        }
        final done = metres / (_metresPerFloor * ride.floors.abs());
        if (done > 0.03) progress = done.clamp(0.0, 0.9).toDouble();
      } else if (_rideSteps > 0) {
        progress = (_rideSteps / (_stairSteps * ride.floors.abs())).clamp(0.0, 1.0).toDouble();
      }
    }
    return FloorWait(
      from: ride.fromFloor,
      to: ride.toFloor,
      via: ride.via,
      progress: progress,
      automatic: floorSensing != null,
    );
  }

  GuideMode get mode {
    if (_simulating) return GuideMode.simulated;
    if (_paused) return GuideMode.paused;
    if (_waiting) return GuideMode.floorChange;
    final t = SensorClock.now();
    final indoor = _geo.placeAt(_f.s).indoor;
    if (!indoor && t - _gpsGoodAt < 4) return GuideMode.gps;
    if (_motion.hasAccelerometer) return GuideMode.steps;
    if (t - _startedAt > 4) return GuideMode.manual;
    return GuideMode.starting;
  }

  /// How far to turn to face the way to go: -180..180, positive = right.
  /// Null without a compass, or while you are walking (then the route
  /// direction is shown anyway).
  double? get turnToRoute {
    final h = _motion.heading, at = _motion.headingAt;
    if (h == null || at == null || _simulating) return null;
    final t = SensorClock.now();
    if (t - at > 1.5) return null;
    final last = _lastStepT;
    // While walking only when going the wrong way.
    if (last != null && t - last < 2.5 && _awaySteps < 3) return null;
    final p = pose.value;
    if (p == null) return null;
    return RouteGeometry.wrap180(p.bearing - h);
  }

  // ------------------------------------------------------------- control

  /// Starts every sensor. Safe to call once.
  Future<void> start() async {
    if (_running || _disposed) return;
    _running = true;
    _startedAt = SensorClock.now();
    _lastFrame = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble('guide.stepLength');
      if (saved != null && saved >= 0.45 && saved <= 1.0) _stepLength = saved;
      final stairs = prefs.getDouble('guide.stairSteps');
      if (stairs != null && stairs >= 14 && stairs <= 40) _stairSteps = stairs;
    } catch (_) {}
    await _baro.load();
    if (_disposed || !_running) return;

    if (startFloorKnown) {
      final place = _geo.placeAt(0);
      if (place.indoor) _startRefFloor = place.floor;
    }
    _motion.start(onStep: _onStep, onSegment: _onSegment, onLift: _onLift, onLiftStart: _onLiftStart);
    _baro.start();
    _baroOn = true;
    _baro.addListener(_onPressure);
    _baro.refreshWeather();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());

    final problem = await LocationService.permissionProblem();
    if (_disposed || !_running) return;
    if (problem != null) {
      _gpsProblem = problem;
      _changed();
      return;
    }
    _gpsSub = LocationService.follow().listen(_onFix, onError: (Object _) {});
  }

  /// Stops every sensor (navigation ended or the screen closed).
  void stop() {
    if (!_running) return;
    _running = false;
    _ticker?.cancel();
    _ticker = null;
    _gpsSub?.cancel();
    _gpsSub = null;
    _motion.stop();
    if (_baroOn) {
      _baro.removeListener(_onPressure);
      _baro.stop();
      _baroOn = false;
    }
    _saveStepLength();
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    // [pose] is left alone: map widgets may still unsubscribe from it.
    super.dispose();
  }

  /// Location was off / not allowed: try again (after the user fixed it).
  Future<void> retryGps() async {
    if (!_running || _gpsSub != null) return;
    final problem = await LocationService.permissionProblem();
    if (_disposed || !_running) return;
    _gpsProblem = problem;
    if (problem == null) {
      _gpsSub = LocationService.follow().listen(_onFix, onError: (Object _) {});
    }
    _changed();
  }

  Future<void> _saveStepLength() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('guide.stepLength', _stepLength);
    } catch (_) {}
  }

  /// Turn auto-follow off (the arrow stays; Next / Back move it) or back on.
  void setPaused(bool on) {
    if (_paused == on) return;
    _paused = on;
    if (!on) {
      _lastStepT = null;
      _f.v = 0;
      _lastFrame = null;
    }
    _changed();
  }

  /// "Simulate walk": moves along the route at walking pace and takes the
  /// stairs / lifts by itself. For trying guidance at a desk.
  void setSimulating(bool on) {
    if (_simulating == on) return;
    _simulating = on;
    _simWaitSince = null;
    _f.v = on ? _walkSpeed : 0;
    _changed();
  }

  /// Next / Back / a scanned sign: jump to the start of step [k].
  void jumpToStep(int k, {bool fromSign = false}) {
    final steps = _route.steps;
    if (steps.isEmpty || _geo.stepAlong.length != steps.length) return;
    k = k.clamp(0, steps.length - 1).toInt();
    final target = _geo.stepAlong[k];
    _confirmedS = 0;
    for (final r in _geo.rides) {
      if (r.to <= target + 0.02) _confirmedS = r.to + 0.01;
    }
    final at = math.min(_geo.length, target + 0.01);
    _f.reset(at, sigma: fromSign ? 1.5 : 2.5, speed: 0);
    _anchorS = at;
    _segs.clear();
    _p0 = null;
    _climbing = false;
    _pendingExtra = false;
    _floorOffset = 0;
    _mismatch = null;
    _offFixes = 0;
    _offPos = null;
    _rejects = 0;
    _rideFor = null;
    _rideSteps = 0;
    _absorbLevel = _absorbStair = null;
    _arrived = k >= steps.length - 1;
    if (!_arrived) _rememberedArrival = false;
    _lastFrame = null; // jump, do not glide
    if (fromSign) {
      final place = _geo.placeAt(at);
      if (place.indoor) _baro.setFloor(place.floor, basis: 'sign');
    }
    frame();
    _changed();
  }

  /// "I'm on floor N" on the floor card.
  void confirmFloor() {
    final r = _holdRide;
    if (r == null || !_waiting) return;
    // No barometer: your tap says how many steps a floor of these stairs is.
    if (!hasBarometer && r.via == 'stairs' && _rideFor == r && r.floors != 0 && _rideSteps >= 8) {
      final perFloor = _rideSteps / r.floors.abs();
      _stairSteps = (0.6 * _stairSteps + 0.4 * perFloor).clamp(14.0, 40.0).toDouble();
      _saveStairSteps();
    }
    _confirm(r, by: 'you');
    _absorbLevel = _absorbStair = null;
    _baro.setFloor(r.toFloor, basis: 'you');
    frame();
    _changed();
  }

  /// "I'm on the route's floor" on the wrong-floor banner.
  void dismissMismatch() {
    _floorOffset = 0;
    _mismatch = null;
    final place = _geo.placeAt(_f.s);
    if (place.indoor) _baro.setFloor(place.floor, basis: 'you');
    _changed();
  }

  /// "I've arrived" (or the arrival was detected).
  void markArrived() {
    _arrived = true;
    _changed();
  }

  /// A new route from where you are (after going off the path). You are at
  /// its start.
  void replaceRoute(NavigationRoute route, {double sigma = 4}) {
    _route = route;
    _geo = RouteGeometry(route);
    _f = AlongFilter(sigma: sigma);
    _planNorthCache.clear();
    _confirmedS = 0;
    _anchorS = 0;
    _segs.clear();
    _p0 = null;
    _climbing = false;
    _pendingExtra = false;
    _floorOffset = 0;
    _mismatch = null;
    _offFixes = 0;
    _offPos = null;
    _rejects = 0;
    _rerouteFrom = null;
    _arrived = false;
    _rememberedArrival = false;
    _rideFor = null;
    _rideSteps = 0;
    _absorbLevel = _absorbStair = null;
    _lastFrame = null;
    _wasIndoor = null;
    frame();
    _changed();
  }

  /// The screen tried a new route (worked or not): GPS may ask again later.
  void rerouteHandled() {
    _rerouteFrom = null;
    _offFixes = 0;
  }

  // ---------------------------------------------------------- the engine

  FloorRide? get _holdRide => _geo.nextRide(_confirmedS);

  bool get _waiting {
    final r = _holdRide;
    return r != null && _f.s >= r.from - 0.01 && !_arrived;
  }

  /// Climbing the route's stairs / riding its lift (also after the new
  /// floor was confirmed early, until the climb ends): steps and turns
  /// then do not move you along the floor. A climb anywhere else (a ramp, a
  /// pressure blip) does not stop your steps from moving you.
  bool get _climbNearRide {
    if (!_climbing) return false;
    if (_pendingExtra) return true;
    final r = _holdRide;
    return r != null && r.from - _f.s <= _rideNear;
  }

  void _clamp() {
    final hold = _holdRide;
    final lim = hold != null ? hold.from : _geo.length;
    if (_f.s > lim) {
      _f.s = lim;
      if (_f.v > 0) _f.v = 0;
    }
    if (_f.s < 0) _f.s = 0;
    if (hold == null && _geo.length - _f.s <= 3.0) _arrived = true;
  }

  void _predict(double t) {
    _f.predict(t);
    _clamp();
  }

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

  void _onStep(double t, double? gap) {
    _stepTimes.addLast(t);
    while (_stepTimes.isNotEmpty && t - _stepTimes.first > 60) {
      _stepTimes.removeFirst();
    }
    if (!_running || _paused || _simulating) return;
    _predict(t);
    final gpsGood = t - _gpsGoodAt < 3.0;
    double v, r;
    if (gap != null) {
      v = _stepLength / gap.clamp(0.3, 1.5);
      r = gpsGood ? 0.35 * 0.35 : 0.2 * 0.2;
    } else {
      v = _stepLength / 0.55;
      r = 0.4 * 0.4;
    }
    // Waiting at / riding the stairs or lift: steps do not move you along.
    if (_waiting) {
      _stairStep(gap);
      return;
    }
    if (_climbNearRide) return;
    // Just off the stairs at a full count, still climbing: wait.
    if (_absorbStep(gap)) return;
    // Inside, walking the wrong way (the phone held like a map points
    // backwards): "Turn around" is shown. The arrow keeps following your
    // steps (a compass can be off by a lot near steel and wiring indoors).
    _awaySteps = _walkingAway(t) ? _awaySteps + 1 : 0;
    _f.updateVelocity(v, r);
    _lastStepT = t;
    _clamp();
  }

  double get _metresPerFloor => _baro.hPaPerFloor / FloorBarometer.hPaPerMetre;

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
    _stairSteps = (0.5 * _stairSteps + 0.5 * perFloor).clamp(14.0, 40.0).toDouble();
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
        _stairSteps = (0.5 * _stairSteps + 0.5 * perFloor).clamp(14.0, 40.0).toDouble();
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
  void _onLiftStart(int direction, double startedAt, double speed) {
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
  void _onLift(double metres) {
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

  /// The compass says you face away from the route (inside, phone in hand).
  bool _walkingAway(double t) {
    final h = _motion.heading, at = _motion.headingAt;
    if (h == null || at == null || t - at > 1.0 || !_motion.inHand) return false;
    if (!_geo.placeAt(_f.s).indoor) return false; // outside GPS sorts it out
    return RouteGeometry.wrap180(h - _geo.bearingAt(_f.s)).abs() > 135;
  }

  void _tick() {
    if (!_running) return;
    final t = SensorClock.now();
    if (_simulating) _simulate(t);
    _predict(t);
    if (!_paused && !_simulating) {
      _checkTurns(t);
      final last = _lastStepT;
      final stopped = last == null || t - last > 2.0;
      final left = _geo.length - _f.s;
      final near = left <= math.max(4.0, 1.5 * _f.sigma);
      // Stopped close to the end (after walking a little): arrived.
      if (stopped && near && !_waiting && left <= 8.0 && _f.s >= 1.0) _arrived = true;
      // No steps lately and GPS does not say you are moving: standing still.
      if ((last == null || t - last > 1.4) && t - _gpsSpeedAt > 2.5) {
        _f.updateVelocity(0, 0.15 * 0.15);
      }
    }
    if (_waiting && _f.v > 0) _f.v = 0;
    _clamp();
    _doorReference();
    if (!_paused && !_simulating) {
      _wifiFloorCheck(t);
      if (_waiting) _trackRide(); // the lift counts start when the card shows
      _liftTick(t);
    }
    final lf = _lastFrame;
    if (lf == null || t - lf > 0.5) frame(t); // no screen frames (e.g. covered)
    _publish();
  }

  void _simulate(double t) {
    if (_waiting) {
      final since = _simWaitSince ??= t;
      if (t - since > 4) {
        final r = _holdRide;
        if (r != null) _confirm(r, by: 'sim');
        _simWaitSince = null;
      }
      return;
    }
    _f.v = _walkSpeed;
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

  void _onFix(Position p) {
    final t = SensorClock.now();
    _lastFix = p;
    if (!_running || _paused || _simulating) return;
    _predict(t);
    final acc = p.accuracy;
    final place = _geo.placeAt(_f.s);
    _outsideReference(p, place.indoor, t);
    final maxAcc = place.indoor ? 8.0 : 25.0;
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
    if (fix.off > math.max(25.0, acc * 1.2)) {
      _offFixes++;
      if (!place.indoor) {
        _offPos = GeoPoint(p.latitude, p.longitude);
        if (_offFixes >= 3 && _rerouteFrom == null) {
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
      if (_rejects >= 5 && acc <= 15 && !place.indoor) {
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

  /// Outside with a sharp fix right next to the building: ground floor.
  void _outsideReference(Position p, bool indoor, double t) {
    if (indoor || p.accuracy > 10 || _climbing || t - _lastOutsideRef < 60) return;
    final near = _geo.project(p.latitude, p.longitude, keys: const {'f0'});
    if (near == null || near.off > 25) return;
    _lastOutsideRef = t;
    _baro.setFloor(0, basis: 'outside');
  }

  void _onSegment(double angle, double t0, double t1) {
    if (_waiting || _climbNearRide) {
      _segs.clear();
      return;
    }
    _segs.add((angle, t0, t1));
  }

  /// Once the turning has settled, decide what the turn segments were and,
  /// if they were the route's corners, correct the position.
  void _checkTurns(double t) {
    if (_segs.isEmpty || _motion.turns.turning || t - _segs.last.$3 < _settle) return;
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
                (c.turn.abs() - angle.abs()).abs() <= _angleTol &&
                (hold == null || c.along <= hold.from + 0.5) &&
                (c.along - at).abs() <= window)
              c,
        ];

    final big = [for (final s in segs) if (s.$1.abs() >= _minTurn) s];
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
    if (best == null && net.abs() >= _minTurn) {
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
      _stepLength = (_stepLength * math.sqrt(ratio)).clamp(0.45, 1.0).toDouble();
    }
    _f.updatePosition(z, 1.5 * 1.5);
    _anchorS = corner.along;
    _clamp();
  }

  /// Floors from air pressure, in climb episodes: while the pressure changes
  /// you are on stairs or in a lift (steps do not move you along the floor);
  /// when it settles, the change is counted in whole floors and compared
  /// with the route.
  void _onPressure(double p, double t) {
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
      if (d5.abs() > _climbDp) {
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
    if (r != null && p0 != null && r.from - _f.s <= _rideNear) {
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
    if (d3.abs() < _calmDp) {
      final calm = _calmSince ??= t;
      if (t - calm >= _calmHold) {
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
    final close = r != null && r.from - _f.s <= _rideNear;
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
      if (at >= _f.s - 15 && at <= _f.s + _rideNear) return true;
    }
    return false;
  }

  /// You are on the new floor of ride [r].
  void _confirm(FloorRide r, {double? base, bool afterClimb = false, double walked = 0, required String by}) {
    var extra = walked;
    final end = _climbEndT;
    if (afterClimb && end != null) {
      extra = math.min(10.0, _stepLength * _stepsSince(end));
    }
    final now = _press.p;
    if (base != null && now != null && r.floors != 0) {
      _baro.learnFloorHeight((base - now).abs() / r.floors.abs());
    }
    _confirmedS = r.to + 0.01;
    _f.reset(math.min(_geo.length, r.to + 0.01 + extra), sigma: 1.5, speed: _f.v);
    _anchorS = _f.s;
    _segs.clear();
    _floorOffset = 0;
    _mismatch = null;
    _simWaitSince = null;
    _rideFor = null;
    _rideSteps = 0;
    _liftRight = 0;
    _liftWalk = 0;
    _liftStills = 0;
    _liftPushes = 0;
    _liftStartAt = null;
    _wifiAgree = 0;
    _baro.rememberFloor(r.toFloor);
    _notice = r.toFloor == 0 ? "You're on the ground floor" : "You're on floor ${r.toFloor}";
    _clamp();
    _changed();
  }

  // ------------------------------------------------------------- display

  /// Call on every screen frame: moves the arrow smoothly to where the
  /// filter says you are (never backwards by a little; jumps on a floor
  /// change or a big correction) and updates [pose].
  void frame([double? now]) {
    if (!_geo.usable) return;
    final t = now ?? SensorClock.now();
    var target = _f.at(t);
    final hold = _holdRide;
    if (hold != null) target = math.min(target, hold.from);
    target = target.clamp(0.0, _geo.length).toDouble();
    final run = _geo.runAt(target);
    final last = _lastFrame;
    if (last == null) {
      _shown = target;
    } else {
      final dt = t - last;
      if ((target - _shown).abs() > 8.0 || run != _shownRun) {
        _shown = target; // a floor change or a big correction: jump
      } else if (target < _shown && _shown - target < 3.0) {
        // A small step back: wait for the estimate instead of reversing.
      } else if (dt > 0) {
        _shown += (target - _shown) * (1 - math.exp(-dt / 0.25));
      }
    }
    _shownRun = run;
    _lastFrame = t;

    final spot = _geo.at(_shown);
    final h = _motion.heading, ha = _motion.headingAt;
    final heading = (h != null && ha != null && t - ha < 1.5 && !_simulating) ? h : null;
    final fix = _lastFix;
    var accuracy = _f.sigma;
    if (!spot.indoor && fix != null && t - _gpsGoodAt < 4) {
      accuracy = math.min(accuracy, fix.accuracy);
    }
    final off = _offPos;
    final next = LivePose(
      along: _shown,
      geo: off ?? spot.geo,
      indoor: spot.indoor,
      floor: spot.floor,
      plan: spot.plan,
      bearing: spot.bearing,
      planAngle: spot.planAngle,
      planNorth: spot.indoor ? _planNorth(spot.floor) : null,
      heading: heading,
      accuracy: accuracy.clamp(2.0, 30.0).toDouble(),
      offRoute: off != null,
    );
    final prev = pose.value;
    if (prev == null ||
        (prev.along - next.along).abs() > 0.005 ||
        prev.offRoute != next.offRoute ||
        prev.indoor != next.indoor ||
        prev.floor != next.floor ||
        (prev.heading == null) != (next.heading == null) ||
        (prev.heading != null && next.heading != null && RouteGeometry.wrap180(prev.heading! - next.heading!).abs() > 0.5) ||
        (prev.accuracy - next.accuracy).abs() > 0.5) {
      pose.value = next;
    }

    // The step being walked and the metres that count down.
    final steps = _route.steps;
    var k = _geo.stepAt(_shown);
    if (k < 1 && steps.length > 1) k = 1; // step 0 is "you are here"
    if (_arrived) {
      k = steps.length - 1;
      if (!_rememberedArrival) {
        _rememberedArrival = true;
        if (spot.indoor) _baro.rememberFloor(spot.floor);
      }
    }
    _stepIndex = k;
    final nextAt = k + 1 < _geo.stepAlong.length ? _geo.stepAlong[k + 1] : _geo.length;
    _toNext = math.max(0.0, nextAt - _shown) * _geo.scale;
    _remaining = math.max(0.0, _geo.length - _shown) * _geo.scale;
    _publish();
  }

  final Map<int, double?> _planNorthCache = {};

  /// The floor plan's turn against the compass (one value per floor).
  double? _planNorth(int floor) {
    if (_planNorthCache.containsKey(floor)) return _planNorthCache[floor];
    final v = _geo.planNorthAt(_shown);
    if (v != null) _planNorthCache[floor] = v;
    return v;
  }

  /// Tell the screen when something it shows has changed (whole metres,
  /// the step, the floor card ...), not on every frame.
  void _publish() {
    final w = wait;
    final sig = [
      _stepIndex,
      _toNext.round(),
      _remaining.round(),
      mode.index,
      _arrived,
      w?.to,
      w == null ? null : ((w.progress ?? -1) * 10).round(),
      _mismatch,
      _rerouteFrom == null,
      _gpsProblem == null,
      _notice,
      (_lastFix?.accuracy ?? -1).round(),
      turnToRoute == null ? null : (turnToRoute! / 30).round(),
      pose.value?.indoor,
      pose.value?.floor,
      _paused,
      _simulating,
    ].join('|');
    if (sig == _signature) return;
    _signature = sig;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }
}
