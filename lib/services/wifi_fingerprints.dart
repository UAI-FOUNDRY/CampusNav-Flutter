import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/start_point.dart';
import 'api_service.dart';

/// One Wi-Fi scan: access point (BSSID) -> signal strength (dBm).
class WifiScan {
  final Map<String, double> rssi;
  final DateTime at;

  const WifiScan(this.rssi, this.at);

  /// Too few networks to tell places apart.
  bool get tooFew => rssi.length < 3;
}

/// A scan taken at a known spot ("fingerprint").
class WifiSample {
  final String spot;
  final int floor;
  final Map<String, double> rssi;
  final DateTime at;

  const WifiSample(this.spot, this.floor, this.rssi, this.at);

  Map<String, dynamic> toJson() => {
        'spot': spot,
        'floor': floor,
        'at': at.toUtc().toIso8601String(),
        'aps': {for (final e in rssi.entries) e.key: e.value.round()},
      };

  static WifiSample? fromJson(dynamic j) {
    if (j is! Map) return null;
    final spot = j['spot']?.toString();
    final aps = j['aps'];
    if (spot == null || spot.isEmpty || aps is! Map) return null;
    final rssi = <String, double>{};
    for (final e in aps.entries) {
      final v = e.value;
      if (v is num) rssi[e.key.toString().toLowerCase()] = v.toDouble();
    }
    if (rssi.length < 3) return null;
    return WifiSample(
      spot,
      int.tryParse('${j['floor'] ?? 0}') ?? 0,
      rssi,
      DateTime.tryParse('${j['at'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// What the Wi-Fi says about where you are.
class WifiGuess {
  /// Spot id -> probability (only spots that have fingerprints).
  final Map<String, double> probability;

  /// Best spot when the Wi-Fi is clear about it (with its close neighbours
  /// it has at least 85 % of the probability), else null.
  final String? spot;

  /// The floor, when the Wi-Fi is clear about it.
  final int? floor;

  /// RMS dB difference of the best match (lower is better).
  final double? bestDistance;

  const WifiGuess({this.probability = const {}, this.spot, this.floor, this.bestDistance});

  static const none = WifiGuess();
  bool get any => probability.isNotEmpty;
}

/// Room-level "where am I" indoors from Wi-Fi, learned on the go (Android).
///
/// GPS cannot tell rooms apart inside a building, but the Wi-Fi networks a
/// phone hears (and how strongly) differ from room to room and floor to
/// floor. So every time the app is TOLD exactly where you are (you pick
/// your spot in "Where exactly are you?", you scan a sign) it keeps the scan
/// as that spot's fingerprint. Next time, "Use my location" compares the
/// scan with the fingerprints and can name the room and floor by itself.
///
/// Fingerprints are kept on the phone and shared through the backend
/// (`/api/wifi`), so everyone's confirmations help everyone. Only access
/// point ids and signal strengths are stored, never who or when exactly.
///
/// iPhones do not let apps scan Wi-Fi: there this is simply off.
class WifiFingerprints {
  WifiFingerprints._();
  static final WifiFingerprints instance = WifiFingerprints._();

  static const MethodChannel _channel = MethodChannel('campusnav/wifi');
  static const double _missing = -95; // dBm for "not heard"
  static const double _considered = -85; // compare APs at least this strong
  static const int _perSpot = 6; // fingerprints kept per spot
  static const int _maxLocal = 900;

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final List<WifiSample> _local = [];
  final List<WifiSample> _shared = [];
  bool _loaded = false;
  DateTime? _sharedAt;
  SharedPreferences? _prefs;

  /// How many spots have at least one fingerprint.
  int get spotCount => {for (final s in _local) s.spot, for (final s in _shared) s.spot}.length;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      _local.addAll(_decodeList(prefs.getString('wifi.local')));
      _shared.addAll(_decodeList(prefs.getString('wifi.shared')));
      final at = prefs.getInt('wifi.sharedAt');
      if (at != null) _sharedAt = DateTime.fromMillisecondsSinceEpoch(at);
    } catch (_) {}
    unawaited(_refreshShared());
  }

  static List<WifiSample> _decodeList(String? body) {
    if (body == null || body.isEmpty) return const [];
    try {
      final data = jsonDecode(body);
      final list = data is Map ? data['samples'] : data;
      if (list is! List) return const [];
      return [for (final j in list) WifiSample.fromJson(j)].whereType<WifiSample>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// Everyone's fingerprints from the backend, at most once an hour.
  Future<void> _refreshShared() async {
    if (ApiService.useMock) return;
    final at = _sharedAt;
    if (at != null && DateTime.now().difference(at) < const Duration(hours: 1)) return;
    try {
      final res = await http
          .get(Uri.parse('${ApiService.baseUrl}/api/wifi'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final list = _decodeList(res.body);
      _shared
        ..clear()
        ..addAll(list);
      _sharedAt = DateTime.now();
      _prefs?.setString('wifi.shared', jsonEncode({'samples': [for (final s in list) s.toJson()]}));
      _prefs?.setInt('wifi.sharedAt', _sharedAt!.millisecondsSinceEpoch);
    } catch (_) {
      // Offline or an older backend without /api/wifi: local ones only.
    }
  }

  /// Scans the Wi-Fi networks around (takes 2-5 s). Null when not possible
  /// (iPhone, no permission, Wi-Fi scanning off) or nothing usable was heard.
  /// Android allows only a few scans a minute; then the last scan (if it is
  /// at most [maxAge] old) is used.
  Future<WifiScan?> scan({Duration maxAge = const Duration(seconds: 30)}) async {
    if (!supported) return null;
    try {
      final raw = await _channel
          .invokeListMethod<Map<dynamic, dynamic>>('scan', {'fresh': true})
          .timeout(const Duration(seconds: 9));
      if (raw == null) return null;
      return _clean(raw, maxAge);
    } catch (_) {
      return null;
    }
  }

  /// Keeps fresh, audible access points; drops lone phone hotspots
  /// (locally administered ids whose network name appears only once).
  static WifiScan? _clean(List<Map<dynamic, dynamic>> raw, Duration maxAge) {
    final ssidCount = <String, int>{};
    for (final r in raw) {
      final ssid = (r['ssid'] ?? '').toString();
      if (ssid.isNotEmpty) ssidCount[ssid] = (ssidCount[ssid] ?? 0) + 1;
    }
    final kept = <MapEntry<String, double>>[];
    for (final r in raw) {
      final bssid = (r['bssid'] ?? '').toString().toLowerCase();
      final level = r['level'];
      final age = r['ageMs'];
      if (bssid.length < 11 || level is! num) continue;
      if (age is num && age > maxAge.inMilliseconds) continue;
      if (level < -90) continue;
      final ssid = (r['ssid'] ?? '').toString();
      final first = int.tryParse(bssid.substring(0, 2), radix: 16) ?? 0;
      final local = (first & 0x02) != 0;
      if (local && (ssidCount[ssid] ?? 0) < 2) continue;
      kept.add(MapEntry(bssid, level.toDouble()));
    }
    if (kept.length < 3) return null;
    kept.sort((a, b) => b.value.compareTo(a.value));
    return WifiScan(Map.fromEntries(kept.take(30)), DateTime.now());
  }

  /// You are at [spot] on [floor] for sure: keep [scan] as its fingerprint
  /// (and share it).
  Future<void> learn(String spot, int floor, WifiScan scan) async {
    if (scan.tooFew) return;
    await load();
    final sample = WifiSample(spot, floor, scan.rssi, scan.at);
    // A second confirmation within a minute replaces the first.
    _local.removeWhere((s) => s.spot == spot && scan.at.difference(s.at).inSeconds.abs() < 60);
    _local.add(sample);
    final mine = [for (final s in _local) if (s.spot == spot) s];
    if (mine.length > _perSpot) {
      final drop = mine.take(mine.length - _perSpot).toSet();
      _local.removeWhere(drop.contains);
    }
    if (_local.length > _maxLocal) _local.removeRange(0, _local.length - _maxLocal);
    _prefs?.setString('wifi.local', jsonEncode({'samples': [for (final s in _local) s.toJson()]}));
    if (!ApiService.useMock) {
      try {
        await http
            .post(
              Uri.parse('${ApiService.baseUrl}/api/wifi'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(sample.toJson()),
            )
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        // Kept on the phone anyway.
      }
    }
  }

  /// RMS dB difference over the APs heard well in either; null if they
  /// share fewer than 3.
  static double? distance(Map<String, double> a, Map<String, double> b) {
    final keys = <String>{
      for (final e in a.entries) if (e.value >= _considered) e.key,
      for (final e in b.entries) if (e.value >= _considered) e.key,
    };
    var common = 0;
    var sum = 0.0;
    for (final k in keys) {
      final x = a[k], y = b[k];
      if (x != null && y != null) common++;
      final d = math.max(x ?? _missing, _missing) - math.max(y ?? _missing, _missing);
      sum += d * d;
    }
    if (common < 3 || keys.isEmpty) return null;
    return math.sqrt(sum / keys.length);
  }

  /// Which spot (and floor) [scan] looks like. [spots] gives each spot's
  /// position, so close neighbours count as one answer.
  WifiGuess guess(WifiScan scan, Map<String, StartPoint> spots) {
    // Best (closest) fingerprint per spot.
    final best = <String, double>{};
    final floorOf = <String, int>{};
    for (final s in [..._shared, ..._local]) {
      final d = distance(scan.rssi, s.rssi);
      if (d == null) continue;
      final old = best[s.spot];
      if (old == null || d < old) {
        best[s.spot] = d;
        floorOf[s.spot] = s.floor;
      }
    }
    if (best.isEmpty) return WifiGuess.none;
    final d0 = best.values.reduce(math.min);
    // Relative likelihood: a match 1.5 dB worse is half as likely.
    final weight = <String, double>{
      for (final e in best.entries) e.key: math.exp(-0.5 * math.pow((e.value - d0) / 1.5, 2)),
    };
    final total = weight.values.fold<double>(0, (a, b) => a + b);
    final prob = {for (final e in weight.entries) e.key: e.value / total};
    final top = prob.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

    // The best spot with its neighbours (same floor, within 6 m).
    final tp = spots[top];
    var mass = 0.0;
    final floorMass = <int, double>{};
    for (final e in prob.entries) {
      final f = floorOf[e.key] ?? 0;
      floorMass[f] = (floorMass[f] ?? 0) + e.value;
      final sp = spots[e.key];
      if (e.key == top) {
        mass += e.value;
      } else if (tp != null &&
          sp != null &&
          tp.hasGeo &&
          sp.hasGeo &&
          floorOf[e.key] == floorOf[top] &&
          _metres(tp.lat!, tp.lng!, sp.lat!, sp.lng!) <= 6) {
        mass += e.value;
      }
    }
    final bestFloor = floorMass.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return WifiGuess(
      probability: prob,
      spot: d0 <= 9 && mass >= 0.85 ? top : null,
      floor: d0 <= 10 && bestFloor.value >= 0.8 ? bestFloor.key : null,
      bestDistance: d0,
    );
  }

  /// Fingerprints of one spot (for the sensor sheet).
  int samplesFor(String spot) =>
      [for (final s in [..._shared, ..._local]) if (s.spot == spot) s].length;

  static double _metres(double lat1, double lng1, double lat2, double lng2) {
    final kx = 111320 * math.cos(lat1 * math.pi / 180);
    final dx = (lng2 - lng1) * kx, dy = (lat2 - lat1) * 110574;
    return math.sqrt(dx * dx + dy * dy);
  }
}
