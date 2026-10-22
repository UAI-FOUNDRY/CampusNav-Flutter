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
import 'guide_tuning.dart';
import 'location_service.dart';
import 'motion_sensors.dart';
import 'position_filter.dart';
import 'route_tracker.dart';
import 'wifi_fingerprints.dart';

export 'guide_tuning.dart';

// The guide is one class in four files (one library: they share its
// private members):
//  * live_guide.dart          the class: state, outputs, control, the frame
//  * live_guide_types.dart    what it hands the screen (LivePose, FloorWait ...)
//  * live_guide_position.dart GPS fixes, steps and turns -> where you are
//  * live_guide_floors.dart   stairs, lifts, the barometer -> which floor
part 'live_guide_types.dart';
part 'live_guide_position.dart';
part 'live_guide_floors.dart';

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

  // Every tuning value is in GuideTuning (guide_tuning.dart).
  static const double defaultStepLength = GuideTuning.defaultStepLength;

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
  double _stairSteps = GuideTuning.defaultStairStepsPerFloor; // steps per floor (learned)
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
      if (saved != null && saved >= GuideTuning.minStepLength && saved <= GuideTuning.maxStepLength) {
        _stepLength = saved;
      }
      final stairs = prefs.getDouble('guide.stairSteps');
      if (stairs != null &&
          stairs >= GuideTuning.minStairStepsPerFloor &&
          stairs <= GuideTuning.maxStairStepsPerFloor) {
        _stairSteps = stairs;
      }
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

  // ------------------------------------------------------------- tests

  /// Tests: run without the phone's sensors and GPS; feed them with the
  /// debug calls below and set the time with [SensorClock.debugTime].
  /// Air pressure goes in through [FloorBarometer.add].
  @visibleForTesting
  void debugStart() {
    if (_running || _disposed) return;
    _running = true;
    _startedAt = SensorClock.now();
    _lastFrame = null;
    // Only the listener: the real barometer stream is not started here.
    _baroOn = true;
    _baro.addListener(_onPressure);
  }

  /// Tests: one walking step at [t] ([gap] s after the previous one).
  @visibleForTesting
  void debugStep(double t, double? gap) => _onStep(t, gap);

  /// Tests: one GPS fix.
  @visibleForTesting
  void debugFix(Position p) => _onFix(p);

  /// Tests: one turn of the body ([angle] degrees, clockwise +).
  @visibleForTesting
  void debugTurn(double angle, double t0, double t1) => _onSegment(angle, t0, t1);

  /// Tests: the 10-a-second housekeeping (arrival, standing still ...).
  @visibleForTesting
  void debugTick() => _tick();

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
    _f.v = on ? GuideTuning.simulateSpeed : 0;
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
      _stairSteps = (0.6 * _stairSteps + 0.4 * perFloor).clamp(GuideTuning.minStairStepsPerFloor, GuideTuning.maxStairStepsPerFloor).toDouble();
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
    return r != null && r.from - _f.s <= GuideTuning.rideNearMetres;
  }

  void _clamp() {
    final hold = _holdRide;
    final lim = hold != null ? hold.from : _geo.length;
    if (_f.s > lim) {
      _f.s = lim;
      if (_f.v > 0) _f.v = 0;
    }
    if (_f.s < 0) _f.s = 0;
    if (hold == null && _geo.length - _f.s <= GuideTuning.arriveWithin) _arrived = true;
  }

  void _predict(double t) {
    _f.predict(t);
    _clamp();
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
      if (stopped && near && !_waiting && left <= GuideTuning.arriveWhenStoppedWithin && _f.s >= 1.0) {
        _arrived = true;
      }
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
    _f.v = GuideTuning.simulateSpeed;
  }

  // Sensor callbacks. They stay in the class and hand over to the parts:
  // a listener has to be the very same object when it is removed again
  // (an extension method torn off twice is not).
  void _onFix(Position p) => _gpsFix(p);
  void _onPressure(double p, double t) => _pressureChanged(p, t);
  void _onLift(double metres) => _liftRide(metres);
  void _onLiftStart(int direction, double startedAt, double speed) =>
      _liftStarted(direction, startedAt, speed);

  void _onSegment(double angle, double t0, double t1) {
    if (_waiting || _climbNearRide) {
      _segs.clear();
      return;
    }
    _segs.add((angle, t0, t1));
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
