import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:dchs_motion_sensors/dchs_motion_sensors.dart' as dchs;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sensors_plus/sensors_plus.dart';

/// The phone's motion sensors, used by live guidance next to GPS:
///  * [StepDetector]  - walking steps (accelerometer), to move you indoors,
///  * [TurnDetector]  - turns of your body (gyroscope), to match the route's
///                      corners and correct the step count,
///  * compass heading - which way the phone points (rotation vector), for the
///                      "you are facing" beam and "turn around" hints.
///
/// The barometer (floors) is shared with "Use my location", see
/// floor_barometer.dart.
///
/// None of them needs a permission on Android. iOS asks for "Motion &
/// Fitness" (NSMotionUsageDescription in Info.plist). Phones without a
/// sensor simply give nothing; guidance then leans on GPS and the buttons.

/// One clock for every sensor: seconds since the app started (monotonic,
/// never jumps when the phone's time is changed).
class SensorClock {
  SensorClock._();
  static final Stopwatch _watch = Stopwatch()..start();

  /// Tests: the time to report instead of the real clock (null = real).
  @visibleForTesting
  static double? debugTime;

  static double now() => debugTime ?? _watch.elapsedMicroseconds / 1e6;
}

/// Puts a sensor's own event times on [SensorClock]: the spacing between
/// events comes from the sensor (exact, even when the phone delivers them in
/// batches), the offset from the clock.
class StreamTime {
  double? _offset;
  double? _lastRaw;

  double map(DateTime stamp) {
    final now = SensorClock.now();
    final raw = stamp.microsecondsSinceEpoch / 1e6;
    final last = _lastRaw;
    _lastRaw = raw;
    if (last != null && raw <= last) {
      // Timestamps that do not move forward are no use: arrival time.
      _offset = null;
      return now;
    }
    var off = _offset;
    if (off == null || (raw + off - now).abs() > 0.5) {
      off = now - raw;
      _offset = off;
    }
    return raw + off;
  }
}

typedef StepCallback = void Function(double t, double? gap);
typedef SegmentCallback = void Function(double angle, double t0, double t1);

// ------------------------------------------------------------------ steps

/// Counts walking steps from the plain accelerometer (every phone has one;
/// the "linear acceleration" sensor needs a gyroscope, which cheaper phones
/// do not have).
///
/// The movement signal is |acceleration| minus gravity (gravity measured as
/// a slow average, so it adapts to any phone's calibration). Each step is a
/// bump in it. The threshold adapts to how hard you walk (40 % of your
/// recent step peaks, at least 0.3 m/s²), so gentle walking with the phone
/// held steady counts as well as a brisk walk. Stray bumps (putting the
/// phone down, shifting it in your hand in a lift) are not walking: a walk
/// starts at the third bump in a steady rhythm, and then the first two
/// count too. (Two bumps were enough before; in a lift, hand movements then
/// passed for steps and switched the lift sensing off.)
///
/// Simulated from gentle (0.5 m/s²) to heavy (4 m/s²) walking at 1.4-2.2
/// steps a second: within a few percent; standing with shaky hands for a
/// minute: at most 3 stray steps; gentle walking right after strong stair
/// steps: about 92 % of steps counted (the first one or two are missed).
class StepDetector {
  static const double minGap = 0.3; // s
  static const double maxGap = 2.0;

  double? _g; // gravity magnitude (slow average)
  double _f = 0; // movement signal, smoothed
  double _peakAvg = 0.9; // typical step peak (learned)
  // The largest movement of the last 1.5 s (a falling max queue of (t, f)).
  final ListQueue<(double, double)> _window = ListQueue<(double, double)>();
  bool _inPeak = false;
  double _peakMax = 0;
  double _peakT = 0;
  double _last = -1e9;
  int _streak = 0;
  double? _firstGap;

  /// One sample: |acceleration| WITH gravity (m/s²) at time [t] (seconds),
  /// [dt] since the last one. [onStep] gets the step time and the time since
  /// the previous step (null for the first step of a walk).
  void feed(double magnitude, double t, double dt, StepCallback onStep) {
    final g = _g == null ? magnitude : _g! + (magnitude - _g!) * math.min(1.0, dt / 1.5);
    _g = g;
    _f += (magnitude - g - _f) * math.min(1.0, dt / 0.06);
    final f = _f;
    while (_window.isNotEmpty && _window.last.$2 <= f) {
      _window.removeLast();
    }
    _window.addLast((t, f));
    while (t - _window.first.$1 > 1.5) {
      _window.removeFirst();
    }
    // The threshold follows the learned step size, but never stays above
    // what you are doing now: after strong steps (stairs) it comes down
    // again within a second or two, so gentle steps on the level still
    // count. (It only learned from counted steps before, and got stuck
    // high after stairs: then almost no step on the level was counted.)
    final ref = math.min(_peakAvg, math.max(0.0, _window.first.$2));
    final hi = math.max(0.3, 0.4 * ref);
    final lo = 0.3 * hi;
    if (!_inPeak) {
      if (_f > hi) {
        _inPeak = true;
        _peakMax = _f;
        _peakT = t;
      }
      return;
    }
    if (_f > _peakMax) {
      _peakMax = _f;
      _peakT = t;
    }
    if (_f >= lo) return;
    _inPeak = false;
    final gap = _peakT - _last;
    if (gap < minGap) return;
    _last = _peakT;
    _peakAvg = 0.8 * _peakAvg + 0.2 * math.min(_peakMax, 6.0);
    if (gap > maxGap) {
      _streak = 1; // first bump of a new rhythm
      _firstGap = null;
      return;
    }
    _streak++;
    if (_streak == 2) {
      _firstGap = gap; // two bumps can be the hand: wait for a third
      return;
    }
    if (_streak == 3) {
      final first = _firstGap ?? gap;
      final ratio = gap / first;
      if (ratio < 0.6 || ratio > 1.6) {
        _streak = 2; // no steady rhythm yet: the last two start again
        _firstGap = gap;
        return;
      }
      // A steady rhythm: a walk, and the first two bumps were steps too.
      onStep(_peakT - gap - first, null);
      onStep(_peakT - gap, first);
    }
    onStep(_peakT, gap);
  }
}

// ------------------------------------------------------------------ turns

/// Turns of the body from the gyroscope: the rotation about "up" (gravity),
/// integrated, in degrees clockwise.
///
/// Emits each turn SEGMENT (angle, start, end) when it ends. A 1 s window
/// hides the sway of a phone in a walking hand. What a segment means (a
/// corner, an S-bend, the phone twisted and back) is decided against the
/// route by live guidance.
class TurnDetector {
  static const double startRate = 25.0; // deg/s over 1 s: a turn begins
  static const double endRate = 12.0; // ... and ends

  double yaw = 0;
  final ListQueue<(double, double)> _hist = ListQueue<(double, double)>(); // (t, yaw)
  bool turning = false;
  double _segYaw = 0;
  double _segT = 0;

  /// [rateCw]: degrees a second, clockwise; [dt]: seconds since the last sample.
  void feed(double rateCw, double t, double dt, SegmentCallback onSegment) {
    yaw += rateCw * dt;
    _hist.addLast((t, yaw));
    while (_hist.isNotEmpty && t - _hist.first.$1 > 1.0) {
      _hist.removeFirst();
    }
    final first = _hist.first;
    if (t - first.$1 < 0.9) return;
    final rate = (yaw - first.$2) / (t - first.$1);
    if (!turning) {
      if (rate.abs() > startRate) {
        turning = true;
        _segYaw = first.$2;
        _segT = first.$1;
      }
    } else if (rate.abs() < endRate) {
      turning = false;
      onSegment(yaw - _segYaw, _segT, t);
    }
  }

  void reset() {
    _hist.clear();
    turning = false;
  }
}

// ------------------------------------------------------------------- lift

/// Lift rides from the accelerometer, for phones without a barometer.
///
/// A lift pushes you when it starts (about 1-2 s), runs at a steady speed,
/// and pushes the other way when it stops. Each push, integrated over its
/// second or two, is the lift's speed; the height is that speed times the
/// time between the two pushes. Nothing is integrated twice, so a small
/// sensor error does not grow into metres (the old way did: the card then
/// sat at 100 % and did not close). A sensor error adds to one push and
/// takes from the other, so their average cancels it.
///
/// Hand movements: a push answered by an opposite one within 2 s is the
/// hand, not the lift; pushes much smaller than the start (sway) are
/// ignored. While you walk nothing counts. When the phone is turned the
/// level is measured again, because a cheap sensor reads a slightly
/// different offset in every position (a push under way is kept, and the
/// level measured again after it).
///
/// Simulated on rides of 1-3 floors (0.5-1.6 m/s, floors 3-4.5 m high,
/// sensor offsets, a swaying and fidgeting hand), as part of whole trips:
/// see LiveGuide for when the card closes. Also on jerk-limited lifts up to
/// 4 m/s and 1.5 m/s2 (fast lifts never reach full speed on one floor):
/// 280 of 280 rides measured within 20 %, and no more false rides from hand
/// movements than before.
class LiftMeter {
  static const double _enter = 0.08; // m/s²: a push begins
  static const double _exit = 0.05; // ... and has ended
  static const double _minSpeed = 0.25; // m/s: smaller is not a lift
  static const double _relevel = 0.6; // s to measure the level again
  static const double _minPush = 0.45; // s
  static const double _maxPush = 6.0;
  static const double _minRide = 2.0; // s between the start and stop pushes
  // ... or this much after a start push no hand makes (long and strong):
  // a fast lift stops sooner than _minRide after it on one short floor.
  static const double _quickRide = 1.0; // s
  static const double _longPush = 1.0; // s
  static const double _fastStart = 0.6; // m/s

  double? _lp; // vertical acceleration, low-passed (0.25 s)
  double? _base; // its level while still
  double _hold = 0; // measure the level until then

  // the push being measured
  bool _inPush = false;
  double _pushT0 = 0;
  int _pushSign = 0;
  double _pushDv = 0;
  double _pushWt = 0;
  double _pushW = 0;
  double _pushPeak = 0;
  double? _pushQuietSince;
  bool _pushTilted = false; // the phone was turned during this push

  /// The lift has started (a start push was felt) and not stopped yet.
  bool riding = false;

  /// +1 up, -1 down: the way the current (or last) ride started.
  int direction = 0;
  double _speed = 0;
  double _tStart = 0;
  double _startDur = 0; // how long the current ride's start push(es) lasted (s)

  /// Start pushes felt (the hub tells the guide about each new one).
  int starts = 0;

  /// The current ride: when its start push was (its centre, s) and the
  /// lift's speed it gave (m/s).
  double get startedAt => _tStart;
  double get speed => _speed;

  /// Height so far of the ride under way (metres, up +): speed x time.
  double heightSoFar(double t) => riding ? direction.toDouble() * _speed * math.max(0.0, t - _tStart) : 0.0;

  /// One sample: acceleration along "up" without gravity (m/s²) at [t] (s),
  /// [dt] since the last. While [walking] nothing counts and the level is
  /// followed; when the phone is [tilted] the level is measured again (a
  /// push already under way is kept, and the level re-measured after it).
  /// Returns the height of a ride (metres, up +) when its stop push ends.
  double? feed(double a, double t, double dt, {bool tilted = false, bool walking = false}) {
    final lp = _lp == null ? a : _lp! + (a - _lp!) * math.min(1.0, dt / 0.25);
    _lp = lp;
    final b0 = _base;
    if (walking || (tilted && !_inPush)) {
      _inPush = false;
      _hold = t + _relevel;
      _base = b0 == null ? lp : b0 + (lp - b0) * math.min(1.0, dt / 0.3);
      return null;
    }
    if (tilted) _pushTilted = true;
    if (b0 == null) _hold = t + _relevel;
    if (b0 == null || t < _hold) {
      // The level: an average of the last moments, not one swaying sample.
      _base = b0 == null ? lp : b0 + (lp - b0) * math.min(1.0, dt / 0.3);
      return null;
    }
    final had = _inPush;
    final h = _measure(lp, t, dt);
    if (had && !_inPush && _pushTilted) {
      _pushTilted = false;
      _hold = t + _relevel;
    }
    return h;
  }

  double? _measure(double lp, double t, double dt) {
    final base = _base!;
    final x = lp - base;
    if (!_inPush) {
      _base = base + (lp - base) * math.min(1.0, dt / 4.0);
      if (x.abs() > _enter) {
        _inPush = true;
        _pushT0 = t;
        _pushSign = x > 0 ? 1 : -1;
        _pushDv = 0;
        _pushWt = 0;
        _pushW = 0;
        _pushPeak = 0;
        _pushQuietSince = null;
      }
      if (riding && t - _tStart > 90) riding = false;
      return null;
    }
    final sx = x * _pushSign;
    _pushDv += x * dt;
    if (sx > 0) {
      _pushWt += t * sx * dt;
      _pushW += sx * dt;
      _pushPeak = math.max(_pushPeak, sx);
    }
    if (sx >= _exit) {
      _pushQuietSince = null;
      // Still as strong as its peak after 4 s: an offset, not a push.
      if (t - _pushT0 > _maxPush || (t - _pushT0 > 4.0 && sx > 0.7 * _pushPeak)) {
        _inPush = false;
        _base = lp;
      }
      return null;
    }
    final quiet = _pushQuietSince ??= t;
    if (t - quiet < 0.25) return null;
    _inPush = false;
    final dur = quiet - _pushT0;
    final dv = _pushDv.abs();
    if (dur < _minPush || dv < _minSpeed || _pushPeak > 2.5 || _pushW <= 0) return null;
    return _push(_pushSign, dv, _pushWt / _pushW, dur);
  }

  double? _push(int sign, double dv, double tc, double dur) {
    if (!riding) {
      riding = true;
      direction = sign;
      _speed = dv;
      _tStart = tc;
      _startDur = dur;
      starts++;
      return null;
    }
    final ratio = dv / _speed;
    if (ratio < 0.4) return null; // a small sway in between
    if (sign == direction) {
      if (tc - _tStart < 3.0) {
        // A start in two stages: more speed.
        _tStart = (_tStart * _speed + tc * dv) / (_speed + dv);
        _speed += dv;
        _startDur += dur;
      } else if (ratio > 1.0) {
        _speed = dv; // the first "start" was not the lift
        _tStart = tc;
        _startDur = dur;
      }
      return null;
    }
    final minRide = _startDur >= _longPush && _speed >= _fastStart ? _quickRide : _minRide;
    final back = tc - _tStart < minRide;
    if (ratio > 2.5 || back) {
      if (back && ratio <= 2.5) {
        riding = false; // up and right back down: the hand
      } else {
        direction = sign; // much stronger: this is the real start
        _speed = dv;
        _tStart = tc;
        _startDur = dur;
        starts++;
      }
      return null;
    }
    riding = false;
    return direction.toDouble() * 0.5 * (_speed + dv) * (tc - _tStart);
  }

  /// You walk (out of the lift): a ride under way is over.
  void walking(double t) {
    riding = false;
    _inPush = false;
  }

  void reset() {
    riding = false;
    _inPush = false;
    _base = null;
  }
}

// -------------------------------------------------------------- the hub

/// Starts and stops the motion sensors for live guidance and hands the
/// results over as callbacks. One instance per guidance session.
class MotionSensors {
  final StepDetector steps = StepDetector();
  final TurnDetector turns = TurnDetector();

  /// True once the sensor has sent something (so the phone has it).
  bool hasAccelerometer = false;
  bool hasGyroscope = false;
  bool hasCompass = false;

  /// Steps counted since [start].
  int stepCount = 0;

  /// Smoothed compass heading of the phone's top edge (0 = north), or null.
  double? heading;
  double? headingAt; // SensorClock time of the last heading

  /// Tilt of the phone (degrees): 0/0 when it lies flat, pitch near 90 when
  /// it stands upright (or sits in a pocket).
  double pitch = 90;
  double roll = 0;

  /// Held in front of you like a map (not upright, not in a pocket): then
  /// the top edge points roughly the way you walk.
  bool get inHand => pitch.abs() < 65 && roll.abs() < 50;

  StepCallback? _onStep;
  SegmentCallback? _onSegment;
  void Function(double metres)? _onLift;
  void Function(int direction, double startedAt, double speed)? _onLiftStart;

  /// Walking now: three steps within 3 s, the last one within a second.
  bool walkingAt(double t) {
    final last = _lastStepAt;
    return last != null && t - last <= 1.0 && _recentSteps.where((s) => t - s <= 3).length >= 3;
  }

  /// Lift rides from the accelerometer (used when there is no barometer).
  final LiftMeter lift = LiftMeter();
  double? _lastStepAt;
  final ListQueue<double> _recentSteps = ListQueue<double>();
  double? _lastAccT;
  // Which way gravity points in the phone, a few times a second, to notice
  // the phone being turned (the lift meter measures its level again then).
  final ListQueue<(double, double, double, double)> _upHist = ListQueue<(double, double, double, double)>();
  double _tiltUntil = -1e9;
  final StreamTime _gravTime = StreamTime();
  final StreamTime _magTime = StreamTime();

  // Compass from the magnetometer, for phones without a gyroscope / rotation
  // sensor: turns and the compass beam from it.
  double? _magHeading; // degrees, unwrapped
  double? _lastMagT;

  final List<StreamSubscription<dynamic>> _subs = [];
  final StreamTime _gyroTime = StreamTime();

  // Gravity (m/s², phone axes), low-passed: "up" for the turn rate.
  double _gx = 0, _gy = 0, _gz = 9.8;
  double? _lastGyroT;
  double? _hs, _hc; // heading as a smoothed unit vector (no 359 -> 0 jump)

  bool get running => _subs.isNotEmpty;

  void start({
    required StepCallback onStep,
    required SegmentCallback onSegment,
    void Function(double metres)? onLift,
    void Function(int direction, double startedAt, double speed)? onLiftStart,
  }) {
    stop();
    _onStep = onStep;
    _onSegment = onSegment;
    _onLift = onLift;
    _onLiftStart = onLiftStart;
    const fast = Duration(milliseconds: 20);
    try {
      _subs.add(accelerometerEventStream(samplingPeriod: fast).listen(
        (e) {
          hasAccelerometer = true;
          _gx = _gx * 0.95 + e.x * 0.05;
          _gy = _gy * 0.95 + e.y * 0.05;
          _gz = _gz * 0.95 + e.z * 0.05;
          final t = _gravTime.map(e.timestamp);
          final last = _lastAccT;
          _lastAccT = t;
          if (last == null) return;
          final dt = (t - last).clamp(0.0, 0.1).toDouble();
          steps.feed(math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z), t, dt, _step);
          final g = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
          if (g < 1) return;
          // Acceleration along "up" without gravity, for lift rides.
          final up = (e.x * _gx + e.y * _gy + e.z * _gz) / g - 9.81;
          final ux = _gx / g, uy = _gy / g, uz = _gz / g;
          if (_upHist.isEmpty || t - _upHist.last.$1 >= 0.1) _upHist.addLast((t, ux, uy, uz));
          while (_upHist.length > 2 && t - _upHist.elementAt(1).$1 >= 1.0) {
            _upHist.removeFirst();
          }
          final old = _upHist.first;
          // Turned by more than 15 degrees within a second.
          if (old.$2 * ux + old.$3 * uy + old.$4 * uz < 0.966) _tiltUntil = t + 0.3;
          while (_recentSteps.isNotEmpty && t - _recentSteps.first > 3) {
            _recentSteps.removeFirst();
          }
          final walking = walkingAt(t);
          if (walking && _recentSteps.length >= 4) lift.walking(t); // a ride is over
          final starts = lift.starts;
          final ride = lift.feed(up, t, dt, tilted: t < _tiltUntil, walking: walking);
          if (lift.starts != starts) {
            _onLiftStart?.call(lift.direction, lift.startedAt, lift.speed);
          }
          if (ride != null) _onLift?.call(ride);
        },
        onError: (Object _) {},
        cancelOnError: true,
      ));
    } catch (_) {
      // No accelerometer: guidance uses GPS and the buttons.
    }
    try {
      _subs.add(magnetometerEventStream(samplingPeriod: fast).listen(
        (e) {
          final t = _magTime.map(e.timestamp);
          final h = _headingFrom(_gx, _gy, _gz, e.x, e.y, e.z);
          if (h == null) return;
          final prev = _magHeading;
          final last = _lastMagT;
          _lastMagT = t;
          if (prev == null) {
            _magHeading = h;
            return;
          }
          // Unwrapped and smoothed (the magnetometer is noisy).
          final step = ((h - prev % 360) + 540) % 360 - 180;
          final next = prev + step * 0.2;
          _magHeading = next;
          if (!hasGyroscope && last != null) {
            final dt = (t - last).clamp(0.0, 0.1).toDouble();
            if (dt > 0) turns.feed((next - prev) / dt, t, dt, _segment);
          }
          if (!hasCompass) {
            heading = (next % 360 + 360) % 360;
            headingAt = SensorClock.now();
            final g = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
            if (g > 1) pitch = math.acos((_gz / g).clamp(-1.0, 1.0)) * 180 / math.pi;
          }
        },
        onError: (Object _) {},
        cancelOnError: true,
      ));
    } catch (_) {}
    try {
      _subs.add(gyroscopeEventStream(samplingPeriod: fast).listen(
        (e) {
          hasGyroscope = true;
          final t = _gyroTime.map(e.timestamp);
          final last = _lastGyroT;
          _lastGyroT = t;
          if (last == null) return;
          final dt = (t - last).clamp(0.0, 0.1).toDouble();
          final g = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
          if (g < 1) return;
          // Rotation about "up", clockwise positive, degrees a second.
          final up = (e.x * _gx + e.y * _gy + e.z * _gz) / g;
          turns.feed(-up * 180 / math.pi, t, dt, _segment);
        },
        onError: (Object _) {},
        cancelOnError: true,
      ));
    } catch (_) {}
    _startCompass();
  }

  void _step(double t, double? gap) {
    stepCount++;
    _lastStepAt = t;
    _recentSteps.addLast(t);
    _onStep?.call(t, gap);
  }

  void _segment(double angle, double t0, double t1) => _onSegment?.call(angle, t0, t1);

  /// Compass heading (degrees) of the phone's top edge from gravity [g] and
  /// the magnetic field [m] (phone axes; same maths as Android's
  /// getRotationMatrix). Flat-ish: the top edge; upright: where the back
  /// camera looks. Null when there is no usable direction.
  static double? _headingFrom(double gx, double gy, double gz, double mx, double my, double mz) {
    var hx = my * gz - mz * gy, hy = mz * gx - mx * gz, hz = mx * gy - my * gx;
    final normH = math.sqrt(hx * hx + hy * hy + hz * hz);
    final normG = math.sqrt(gx * gx + gy * gy + gz * gz);
    if (normH < 0.1 || normG < 0.1) return null;
    hx /= normH;
    hy /= normH;
    hz /= normH;
    final ax = gx / normG, ay = gy / normG, az = gz / normG;
    final ny = az * hx - ax * hz, nz = ax * hy - ay * hx;
    final rad = az.abs() > 0.5 ? math.atan2(hy, ny) : math.atan2(-hz, -nz);
    return (rad * 180 / math.pi + 360) % 360;
  }

  Future<void> _startCompass() async {
    try {
      final ok = await dchs.motionSensors.isAbsoluteOrientationAvailable();
      if (!ok || _onStep == null) return;
      // 10 a second. Both setters: the plugin's iOS side swaps the two
      // sensor ids, so this sets the right one on both platforms.
      dchs.motionSensors.absoluteOrientationUpdateInterval = 100000;
      dchs.motionSensors.orientationUpdateInterval = 100000;
      _subs.add(dchs.motionSensors.absoluteOrientation.listen(
        (e) {
          // Both platforms: yaw is counter-clockwise from magnetic north.
          final r = -e.yaw;
          final s0 = _hs, c0 = _hc;
          _hs = s0 == null ? math.sin(r) : s0 * 0.75 + math.sin(r) * 0.25;
          _hc = c0 == null ? math.cos(r) : c0 * 0.75 + math.cos(r) * 0.25;
          heading = (math.atan2(_hs!, _hc!) * 180 / math.pi + 360) % 360;
          headingAt = SensorClock.now();
          pitch = e.pitch * 180 / math.pi;
          roll = e.roll * 180 / math.pi;
          hasCompass = true;
        },
        onError: (Object _) {},
        cancelOnError: true,
      ));
    } catch (_) {
      // No rotation sensor / plugin: no compass beam.
    }
  }

  void stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _onStep = null;
    _onSegment = null;
    _onLift = null;
    _onLiftStart = null;
    _lastGyroT = null;
    _lastAccT = null;
    _lastMagT = null;
    _magHeading = null;
    _recentSteps.clear();
    _upHist.clear();
    turns.reset();
    lift.reset();
  }
}
