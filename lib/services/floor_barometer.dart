import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'motion_sensors.dart';

/// A guess of the floor you are on, from air pressure.
class FloorEstimate {
  final int floor;

  /// Floors above the ground floor as a fraction (1.1 = a little above floor 1).
  final double level;

  /// 0..1: how much to trust [floor]. Low when the reference is old or the
  /// pressure sits between two floors.
  final double confidence;

  /// Where the reference came from: "outside", "door", "sign", "picked",
  /// "stairs", "you" ...
  final String basis;

  const FloorEstimate(this.floor, this.level, this.confidence, this.basis);

  bool get sure => confidence >= 0.6;
}

typedef PressureListener = void Function(double hPa, double t);

/// Which floor the phone is on, from the barometer.
///
/// Air pressure drops about 0.113 hPa per metre up here (warm air, about 200 m
/// above the sea), so one floor of [metresPerFloor] is about 0.45 hPa: easy to
/// see (a phone barometer is steady to about 0.02 hPa once smoothed). Weather
/// moves pressure too, so:
///  * CHANGES over a minute or two (stairs, a lift) are reliable: live
///    guidance counts floors from them without any reference;
///  * the ABSOLUTE floor needs a reference: the pressure on a known floor at a
///    known time. It is set whenever the floor is certain (outside right next
///    to the building, at the door, a confirmed stairs/lift ride, a scanned
///    sign, a place you picked) and corrected for the weather with the
///    Open-Meteo forecast for the campus (free, no key). Offline it is
///    corrected with the daily air-pressure tide and trusted for an hour or two.
///
/// One shared instance: screens [start] / [stop] it (counted).
class FloorBarometer {
  FloorBarometer._();
  static final FloorBarometer instance = FloorBarometer._();

  /// Floor-to-floor height of the main building. Measure it (count the stairs
  /// x riser height) and change it here if it is not 4 m; the app also learns
  /// it from every stairs/lift ride.
  static const double metresPerFloor = 4.0;
  static const double hPaPerMetre = 0.113;

  /// Tests: no weather download.
  @visibleForTesting
  static bool weatherEnabled = true;

  static const double _campusLat = 18.9027;
  static const double _campusLng = 73.3742;

  /// Smoothed pressure in hPa (null until the first reading / no barometer).
  final ValueNotifier<double?> pressure = ValueNotifier<double?>(null);

  /// False once the phone turned out to have no barometer.
  bool available = true;

  /// hPa per floor, learned from stairs/lift rides.
  double hPaPerFloor = metresPerFloor * hPaPerMetre;

  StreamSubscription<BarometerEvent>? _sub;
  int _users = 0;
  DateTime? _readingAt; // when [pressure] was last updated

  /// A reading from the last few seconds.
  bool get isFresh {
    final at = _readingAt;
    return pressure.value != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 3);
  }

  final StreamTime _time = StreamTime();
  final List<PressureListener> _listeners = [];

  double? _refGround; // phone pressure on the ground floor at _refAt
  DateTime? _refAt;
  double? _refWeather; // forecast surface pressure at _refAt
  String _refBasis = '';

  // Hourly forecast surface pressure for the campus (unix seconds, hPa).
  List<int> _wTimes = const [];
  List<double> _wValues = const [];
  DateTime? _wFetched;
  Future<void>? _wLoading;

  bool _loaded = false;
  SharedPreferences? _prefs;

  // The last floor known for sure (any phone, with or without a barometer):
  // a confirmed stairs / lift ride, a sign, a picked spot, an arrival.
  int? _lastFloor;
  DateTime? _lastFloorAt;

  /// Saved learning and the last reference. Safe to call often.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      final hpf = prefs.getDouble('baro.hpf');
      if (hpf != null && hpf >= 0.35 && hpf <= 0.6) hPaPerFloor = hpf;
      final ref = prefs.getString('baro.ref');
      if (ref != null) {
        final m = jsonDecode(ref);
        if (m is Map) {
          _refGround = (m['g'] as num?)?.toDouble();
          final at = m['t'];
          _refAt = at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null;
          _refWeather = (m['w'] as num?)?.toDouble();
          _refBasis = (m['b'] ?? '').toString();
        }
      }
      _lastFloor = prefs.getInt('floor.last');
      final lastAt = prefs.getInt('floor.lastAt');
      if (lastAt != null) _lastFloorAt = DateTime.fromMillisecondsSinceEpoch(lastAt);
      final w = prefs.getString('baro.weather');
      if (w != null) _parseWeather(w, DateTime.fromMillisecondsSinceEpoch(prefs.getInt('baro.weatherAt') ?? 0));
    } catch (_) {
      // Storage unavailable: start fresh.
    }
  }

  // ------------------------------------------------------------ sensor

  void start() {
    _users++;
    if (_sub != null || !available) return;
    try {
      _sub = barometerEventStream(samplingPeriod: const Duration(milliseconds: 200)).listen(
        (e) => add(e.pressure, _time.map(e.timestamp)),
        onError: (Object _) {
          available = false;
          _sub = null;
        },
        cancelOnError: true,
      );
    } catch (_) {
      available = false;
    }
  }

  void stop() {
    _users = math.max(0, _users - 1);
    if (_users == 0) {
      _sub?.cancel();
      _sub = null;
    }
  }

  void addListener(PressureListener l) => _listeners.add(l);
  void removeListener(PressureListener l) => _listeners.remove(l);

  /// One raw reading (hPa) at [t] (SensorClock seconds). Public for tests.
  void add(double hPa, double t) {
    if (hPa < 300 || hPa > 1100) return; // not a real air pressure
    final p = pressure.value;
    final now = DateTime.now();
    final last = _readingAt;
    final fresh = last != null && now.difference(last) < const Duration(seconds: 5);
    _readingAt = now;
    // About 1.5 s of smoothing at 5 readings a second (restarted after a
    // pause, so an old value does not linger).
    final smooth = p == null || !fresh ? hPa : p * 0.85 + hPa * 0.15;
    pressure.value = smooth;
    for (final l in List<PressureListener>.of(_listeners)) {
      l(smooth, t);
    }
  }

  /// The pressure now, waiting up to [timeout] for the first reading.
  Future<double?> read({Duration timeout = const Duration(seconds: 2)}) async {
    if (!available || isFresh) return pressure.value;
    final before = _readingAt;
    start();
    final done = Completer<double?>();
    void listener() {
      if (!done.isCompleted && pressure.value != null && _readingAt != before) {
        done.complete(pressure.value);
      }
    }

    pressure.addListener(listener);
    try {
      return await done.future.timeout(timeout, onTimeout: () => pressure.value);
    } finally {
      pressure.removeListener(listener);
      stop();
    }
  }

  // ---------------------------------------------------------- reference

  /// You are on [floor] for sure (works without a barometer too).
  void rememberFloor(int floor) {
    final now = DateTime.now();
    _lastFloor = floor;
    _lastFloorAt = now;
    _prefs?.setInt('floor.last', floor);
    _prefs?.setInt('floor.lastAt', now.millisecondsSinceEpoch);
  }

  /// The last floor known for sure, if it was at most [within] ago (a hint
  /// for "Use my location" on phones without a barometer).
  int? recentFloor({Duration within = const Duration(minutes: 20)}) {
    final at = _lastFloorAt;
    if (_lastFloor == null || at == null || DateTime.now().difference(at) > within) return null;
    return _lastFloor;
  }

  /// "Right now the phone is on [floor]": remember it as the reference.
  void setFloor(int floor, {required String basis}) {
    rememberFloor(floor);
    final p = pressure.value;
    final at = _readingAt;
    if (p == null || at == null || DateTime.now().difference(at) > const Duration(seconds: 10)) {
      return; // no recent reading: better no reference than a wrong one
    }
    final now = DateTime.now();
    _refGround = p + floor * hPaPerFloor;
    _refAt = now;
    _refWeather = weatherAt(now);
    _refBasis = basis;
    _prefs?.setString(
      'baro.ref',
      jsonEncode({'g': _refGround, 't': now.millisecondsSinceEpoch, 'w': _refWeather, 'b': basis}),
    );
    if (_refWeather == null) refreshWeather();
  }

  /// One floor change measured on stairs or in a lift: [observed] hPa per
  /// floor. Learned slowly, within sane limits.
  void learnFloorHeight(double observed) {
    if (observed < 0.3 || observed > 0.7) return;
    hPaPerFloor = (0.5 * hPaPerFloor + 0.5 * observed).clamp(0.35, 0.6).toDouble();
    _prefs?.setDouble('baro.hpf', hPaPerFloor);
  }

  bool get hasReference => _refGround != null && _refAt != null;

  /// Where the reference came from (for the sensor sheet).
  String get referenceBasis => _refBasis;
  DateTime? get referenceTime => _refAt;

  /// The floor now, or null without a barometer or a usable reference.
  FloorEstimate? estimate({DateTime? now}) {
    final p = pressure.value;
    final g = _refGround, at = _refAt;
    if (p == null || g == null || at == null || !isFresh) return null;
    final t = now ?? DateTime.now();
    final age = t.difference(at);
    if (age.isNegative) return null;

    double ground;
    double trust;
    final wNow = weatherAt(t), wRef = _refWeather;
    if (wNow != null && wRef != null) {
      // The forecast says how much the weather moved the pressure since.
      ground = g + (wNow - wRef);
      final h = age.inMinutes / 60;
      trust = h <= 6
          ? 1.0
          : h <= 24
              ? 0.7
              : h <= 72
                  ? 0.5
                  : h <= 24 * 14
                      ? 0.35
                      : 0.0;
    } else {
      // Offline: only the daily pressure tide is known.
      ground = g + _tide(t) - _tide(at);
      final h = age.inMinutes / 60;
      trust = h <= 1
          ? 0.9
          : h <= 2
              ? 0.6
              : h <= 4
                  ? 0.3
                  : 0.0;
    }
    if (trust <= 0) return null;
    final level = (ground - p) / hPaPerFloor;
    final floor = math.max(0, level.round());
    final off = (level - floor).abs();
    final close = 1 - ((off - 0.12) / 0.33).clamp(0.0, 1.0).toDouble();
    return FloorEstimate(floor, level, trust * close, _refBasis);
  }

  /// How many floors from pressure [from] to [to] (positive = up).
  double floorsBetween(double from, double to) => (from - to) / hPaPerFloor;

  // ------------------------------------------------------------ weather

  /// Semi-diurnal air-pressure tide in the tropics (about ±1 hPa at Karjat),
  /// highest near 10:00 and 22:00 local solar time.
  static double _tide(DateTime t) {
    final u = t.toUtc();
    final solar = u.hour + u.minute / 60 + u.second / 3600 + _campusLng / 15;
    return 1.0 * math.cos(2 * math.pi * (solar - 10) / 12);
  }

  /// Forecast surface pressure (hPa) for the campus at [t], or null.
  double? weatherAt(DateTime t) {
    final times = _wTimes, values = _wValues;
    if (times.length < 2) return null;
    final s = t.millisecondsSinceEpoch / 1000;
    if (s < times.first || s > times.last) return null;
    for (var i = 1; i < times.length; i++) {
      if (times[i] >= s) {
        final t0 = times[i - 1], t1 = times[i];
        final f = t1 == t0 ? 0.0 : (s - t0) / (t1 - t0);
        return values[i - 1] + (values[i] - values[i - 1]) * f;
      }
    }
    return null;
  }

  /// Fetches the campus forecast (Open-Meteo) if the saved one is older than
  /// half an hour. Never throws; offline it simply keeps what it has.
  Future<void> refreshWeather() {
    if (!weatherEnabled) return Future<void>.value();
    final fetched = _wFetched;
    if (fetched != null && DateTime.now().difference(fetched) < const Duration(minutes: 30)) {
      return Future<void>.value();
    }
    return _wLoading ??= _fetchWeather().whenComplete(() => _wLoading = null);
  }

  Future<void> _fetchWeather() async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '$_campusLat',
      'longitude': '$_campusLng',
      'hourly': 'surface_pressure',
      'past_days': '1',
      'forecast_days': '2',
      'timeformat': 'unixtime',
    });
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final now = DateTime.now();
      if (_parseWeather(res.body, now)) {
        _prefs?.setString('baro.weather', res.body);
        _prefs?.setInt('baro.weatherAt', now.millisecondsSinceEpoch);
        // A reference taken without the forecast can be tied to it now.
        final at = _refAt;
        if (_refWeather == null && at != null) _refWeather = weatherAt(at);
      }
    } catch (_) {
      // Offline: keep what we have.
    }
  }

  bool _parseWeather(String body, DateTime fetched) {
    try {
      final data = jsonDecode(body);
      if (data is! Map || data['hourly'] is! Map) return false;
      final hourly = data['hourly'] as Map;
      final rawT = hourly['time'], rawP = hourly['surface_pressure'];
      if (rawT is! List || rawP is! List || rawT.length != rawP.length) return false;
      final times = <int>[];
      final values = <double>[];
      for (var i = 0; i < rawT.length; i++) {
        final p = rawP[i];
        if (p is! num) continue; // missing hour
        final v = rawT[i];
        int? secs;
        if (v is num) {
          secs = v.toInt();
        } else if (v is String) {
          final d = DateTime.tryParse(v.endsWith('Z') ? v : '${v}Z');
          secs = d == null ? null : d.millisecondsSinceEpoch ~/ 1000;
        }
        if (secs == null) continue;
        times.add(secs);
        values.add(p.toDouble());
      }
      if (times.length < 2) return false;
      _wTimes = times;
      _wValues = values;
      _wFetched = fetched;
      return true;
    } catch (_) {
      return false;
    }
  }
}
