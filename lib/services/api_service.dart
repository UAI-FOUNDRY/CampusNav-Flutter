import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/mock_campus.dart';
import '../models/destination.dart';
import '../models/floor_info.dart';
import '../models/route.dart';
import '../models/start_point.dart';

/// Every searchable place plus the floor pictures, from GET /api/graph.
class CampusCatalog {
  final List<Destination> places;
  final List<FloorInfo> floors;
  final String? version;

  /// True when the server could not be reached and this is the copy saved
  /// on the phone from last time (routes still need the server).
  final bool offline;

  /// Everywhere a route can start: every place plus named spots that are not
  /// places (lifts, staircases, lobbies, side doors). Grouped by [StartPoint.group].
  final List<StartPoint> starts;

  const CampusCatalog({
    required this.places,
    required this.floors,
    this.version,
    this.offline = false,
    this.starts = const [],
  });
}

/// What kind of problem it was, so the screen can show the right picture
/// and offer the right fix (retry, pick another start, scan again ...).
enum ApiErrorKind { offline, timeout, noRoute, offCampus, notFound, rateLimited, server }

/// An error with a message that is safe to show to the user.
class ApiException implements Exception {
  final String message;
  final ApiErrorKind kind;
  const ApiException(this.message, [this.kind = ApiErrorKind.server]);

  @override
  String toString() => message;
}

/// The only place in the app that talks to the backend.
///
/// Run against demo data (default):
///   flutter run
/// By default the app uses the backend deployed on Render. Other choices:
///   flutter run --dart-define=USE_MOCK=true          (built-in demo data, no backend)
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:5000   (Flask on your laptop;
///       the Android emulator reaches the laptop as http://10.0.2.2:5000)
class ApiService {
  const ApiService();

  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://campus-nav-api-mokr.onrender.com',
  );

  /// Demo data instead of the backend (--dart-define=USE_MOCK=true). Not a
  /// constant only so tests can switch it on.
  static bool useMock = const bool.fromEnvironment('USE_MOCK', defaultValue: false);

  static const Duration _timeout = Duration(seconds: 8);

  // ---- waking the server
  //
  // The free Render server sleeps after 15 minutes without requests and takes
  // up to about a minute to wake. [wakeUp] (called when the app opens) pings
  // it; requests made meanwhile wait for the ping instead of failing after
  // 8 s, and [waking] lets the app say what is going on.

  /// True while the server is being woken and it is taking a while.
  static final ValueNotifier<bool> waking = ValueNotifier<bool>(false);
  static Future<void>? _wake;
  static bool _awake = false;
  static DateTime? _lastAnswer;

  /// Wakes the server if it may be asleep. Safe to call often: resolves at
  /// once while it is known to be awake.
  static Future<void> wakeUp() {
    if (useMock) return Future<void>.value();
    final last = _lastAnswer;
    // Answered within the last 10 minutes: still awake.
    if (_awake && last != null && DateTime.now().difference(last) < const Duration(minutes: 10)) {
      return Future<void>.value();
    }
    return _wake ??= _ping().whenComplete(() => _wake = null);
  }

  static Future<void> _ping() async {
    // Only say "waking" if it is not answering straight away.
    final slow = Timer(const Duration(seconds: 3), () => waking.value = true);
    final until = DateTime.now().add(const Duration(seconds: 75));
    _awake = false;
    try {
      while (DateTime.now().isBefore(until)) {
        final left = until.difference(DateTime.now());
        try {
          final r = await http.get(Uri.parse('$baseUrl/api/health')).timeout(left);
          if (r.statusCode < 500) {
            _awake = true;
            _lastAnswer = DateTime.now();
            return;
          }
          // 502/503 while the server starts: ask again shortly.
          await Future<void>.delayed(const Duration(seconds: 3));
        } on TimeoutException {
          return;
        } catch (_) {
          return; // offline: the request itself will say so
        }
      }
    } finally {
      slow.cancel();
      waking.value = false;
    }
  }

  /// Search places. An empty query returns every place.
  ///
  /// Typed queries go to GET /api/rooms?q=... (typo tolerant). The full list
  /// comes from [loadCatalog], because /api/rooms answers at most 50 places
  /// and the campus has more than that.
  Future<List<Destination>> searchDestinations([String query = '']) async {
    if (useMock) {
      await Future.delayed(const Duration(milliseconds: 700));
      return MockCampus.search(query);
    }

    if (query.trim().isEmpty) {
      return (await loadCatalog()).places;
    }

    final uri = Uri.parse('$baseUrl/api/rooms')
        .replace(queryParameters: {'q': query, 'limit': '50'});
    return _placesFrom(await _send(() => http.get(uri)));
  }

  static CampusCatalog? _catalog;
  static DateTime? _catalogAt;

  /// The last loaded catalog, if any (no network). Used to give a scanned QR
  /// code its proper name.
  static CampusCatalog? get cachedCatalog => _catalog;

  /// Every place and floor, from GET /api/graph. Kept in memory for a few
  /// minutes (Home and Map share it); [refresh] fetches it again.
  /// Falls back to /api/rooms + /api/floors on a backend without /api/graph.
  Future<CampusCatalog> loadCatalog({bool refresh = false}) async {
    final cached = _catalog;
    final at = _catalogAt;
    if (cached != null &&
        !refresh &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return cached;
    }

    if (useMock) {
      await Future.delayed(const Duration(milliseconds: 500));
      _catalogAt = DateTime.now();
      return _catalog = CampusCatalog(
        places: MockCampus.search(''),
        floors: FloorInfo.fallback,
        starts: MockCampus.startPoints,
      );
    }

    CampusCatalog result;
    try {
      result = await _graphCatalog();
    } on _NoGraph {
      // Older backend: the first 50 places and the floors endpoint.
      final uri = Uri.parse('$baseUrl/api/rooms')
          .replace(queryParameters: {'q': '', 'limit': '50'});
      final places = _placesFrom(await _send(() => http.get(uri)));
      var floors = FloorInfo.fallback;
      try {
        floors = _floorsFrom(
            await _send(() => http.get(Uri.parse('$baseUrl/api/floors'))));
      } on ApiException {
        // Keep the bundled list.
      }
      result = CampusCatalog(places: places, floors: floors, starts: _startsFrom(places, const {}));
    }
    // A saved offline copy is kept for one minute only, so the app tries the
    // server again soon.
    _catalogAt = result.offline
        ? DateTime.now().subtract(const Duration(minutes: 4))
        : DateTime.now();
    return _catalog = result;
  }

  static const _graphKey = 'graph.body';
  static const _graphTagKey = 'graph.etag';

  /// GET /api/graph, saved on the phone. The saved copy's ETag goes with the
  /// request, so an unchanged map costs a tiny 304 instead of 170 KB. With no
  /// connection the saved copy is used (marked [CampusCatalog.offline]).
  /// Throws [_NoGraph] when the server has no /api/graph (older backend).
  Future<CampusCatalog> _graphCatalog() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null; // storage unavailable: just use the network
    }
    final savedBody = prefs?.getString(_graphKey);
    final savedTag = prefs?.getString(_graphTagKey);
    // The first time ever the map is needed: wait for a sleeping server.
    // With a saved map, don't: browse the saved one while it wakes.
    if (savedBody == null) {
      await wakeUp();
    } else {
      unawaited(wakeUp());
    }

    http.Response response;
    try {
      response = await http.get(
        Uri.parse('$baseUrl/api/graph'),
        headers: {if (savedBody != null && savedTag != null) 'If-None-Match': savedTag},
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      // Offline or timed out: the saved map still lets people browse.
      if (savedBody != null) return _parseGraph(savedBody, offline: true);
      _offlineError();
    }

    if (response.statusCode == 304 && savedBody != null) {
      return _parseGraph(savedBody);
    }
    if (response.statusCode == 404) throw const _NoGraph();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (savedBody != null) return _parseGraph(savedBody, offline: true);
      throw _errorFrom(response);
    }
    final catalog = _parseGraph(response.body);
    final tag = response.headers['etag'];
    if (prefs != null) {
      await prefs.setString(_graphKey, response.body);
      if (tag != null) {
        await prefs.setString(_graphTagKey, tag);
      } else {
        await prefs.remove(_graphTagKey);
      }
    }
    return catalog;
  }

  /// Never returns: the "could not reach the server" error.
  Never _offlineError() => throw const ApiException(
        'Could not reach the server. Check that you are online (campus Wi-Fi or data).',
        ApiErrorKind.offline,
      );

  CampusCatalog _parseGraph(String body, {bool offline = false}) {
    dynamic data;
    try {
      data = jsonDecode(body);
    } on FormatException {
      throw const ApiException('The server sent data the app could not read.');
    }
    if (data is! Map || data['rooms'] is! List || data['nodes'] is! List) {
      throw const ApiException('The server sent data the app could not read.');
    }
    final nodes = <String, Map>{
      for (final n in data['nodes'] as List)
        if (n is Map && n['id'] != null) n['id'].toString(): n,
    };
    final places = (data['rooms'] as List)
        .whereType<Map>()
        .map((r) => Destination.fromGraph(r, nodes))
        .whereType<Destination>()
        .where(_isSearchable)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return CampusCatalog(
      places: places,
      floors: _floorsFrom(data['floors']),
      version: data['version']?.toString(),
      offline: offline,
      starts: _startsFrom(places, nodes, data['rooms'] as List),
    );
  }

  static String _floorName(int f) => f == 0 ? 'Ground floor' : 'Floor $f';

  /// Every place, then the named graph spots that are not places. Internal
  /// corridor points ("x__y"), junctions and unnamed dots are left out.
  static List<StartPoint> _startsFrom(
    List<Destination> places,
    Map<String, Map> nodes, [
    List rooms = const [],
  ]) {
    final result = <StartPoint>[];
    final usedNodes = <String>{};
    final usedNames = <String>{};
    for (final r in rooms) {
      if (r is! Map) continue;
      final ids = r['node_ids'] is List ? r['node_ids'] as List : [r['node_id']];
      for (final id in ids) {
        if (id != null) usedNodes.add(id.toString());
      }
    }

    for (final d in places) {
      usedNames.add(d.name.toLowerCase());
      final where = d.isIndoor ? '${d.building} · ${_floorName(d.floor)}' : 'Outside';
      final inside = d.withinName;
      result.add(StartPoint(
        id: d.id,
        name: d.name,
        hint: inside == null ? where : 'Inside the $inside · $where',
        type: d.type,
        group: where,
        floor: d.floor,
        indoor: d.isIndoor,
        lat: d.lat,
        lng: d.lng,
      ));
    }

    for (final n in nodes.values) {
      final id = n['id']?.toString() ?? '';
      final name = (n['name'] ?? '').toString().trim();
      if (id.isEmpty || name.isEmpty || id.contains('__')) continue;
      if (usedNodes.contains(id) || usedNames.contains(name.toLowerCase())) continue;
      final kind = (n['type'] ?? '').toString();
      if (kind == 'junction' && !name.toLowerCase().contains('lobby') &&
          !name.toLowerCase().contains('passage') && !name.toLowerCase().contains('steps')) {
        continue;
      }
      if (name.toLowerCase().contains('junction')) continue;
      final indoor = n['space'] == 'indoor';
      final floor = int.tryParse('${n['floor'] ?? 0}') ?? 0;
      final building = (n['building'] ?? '').toString().isNotEmpty
          ? n['building'].toString()
          : name.contains('Block A')
              ? 'Block A'
              : name.contains('Block B')
                  ? 'Block B'
                  : 'Main building';
      final where = indoor ? '$building · ${_floorName(floor)}' : 'Outside';
      final lower = name.toLowerCase();
      result.add(StartPoint(
        id: id,
        name: name,
        hint: where,
        type: lower.contains('lift')
            ? 'lift'
            : lower.contains('stair')
                ? 'stairs'
                : (kind == 'exit' || lower.contains('door'))
                    ? 'entrance'
                    : 'place',
        group: where,
        floor: floor,
        indoor: indoor,
        lat: double.tryParse('${n['lat']}'),
        lng: double.tryParse('${n['lng']}'),
      ));
    }
    return result;
  }

  /// Floor list from {"floors": [...]} or a plain list. Never empty.
  List<FloorInfo> _floorsFrom(dynamic data) {
    final raw = data is Map ? data['floors'] : data;
    if (raw is! List) return FloorInfo.fallback;
    final floors = raw.map(FloorInfo.tryParse).whereType<FloorInfo>().toList()
      ..sort((a, b) => a.floor.compareTo(b.floor));
    return floors.isEmpty ? FloorInfo.fallback : floors;
  }

  List<Destination> _placesFrom(dynamic data) {
    // Flask answers {"results": [...]}; also accept a plain list.
    final list = data is List
        ? data
        : (data is Map && data['results'] is List ? data['results'] as List : <dynamic>[]);
    return list
        .map((item) => Destination.fromJson(Map<String, dynamic>.from(item as Map)))
        .where(_isSearchable)
        .toList();
  }

  /// Junction dots were in older place lists, but nobody searches for them.
  static bool _isSearchable(Destination d) =>
      d.id.isNotEmpty && !d.name.toLowerCase().contains('junction');

  /// `GET /api/route?from=<id>&to=<id>[&accessible=1]`
  ///
  /// [startName] is only used to label the first step ("You are here").
  Future<NavigationRoute> getRoute({
    required String start,
    required String destination,
    bool stepFree = false,
    String? startName,
    double? startLat, // GPS: the server snaps it to the nearest campus path
    double? startLng,
    int? startFloor, // with GPS: may snap to indoor dots of this floor too
  }) async {
    if (useMock) {
      await Future.delayed(const Duration(milliseconds: 800));
      try {
        return MockCampus.buildRoute(
          startId: start,
          destinationId: destination,
          stepFree: stepFree,
        );
      } on ArgumentError {
        throw const ApiException('No walking route was found for that place.', ApiErrorKind.noRoute);
      }
    }

    final gps = startLat != null && startLng != null;
    final uri = Uri.parse('$baseUrl/api/route').replace(queryParameters: {
      if (gps) 'from_lat': startLat.toString() else 'from': start,
      if (gps) 'from_lng': startLng.toString(),
      if (gps && startFloor != null) 'from_floor': '$startFloor',
      'to': destination,
      if (stepFree) 'accessible': '1',
    });
    final data = await _send(() => http.get(uri));
    if (data is! Map) {
      throw const ApiException('The server sent data the app could not read.');
    }
    return NavigationRoute.fromBackend(
      Map<String, dynamic>.from(data),
      startName: startName ?? 'Your location',
    );
  }

  /// POST /api/estimates   {"start": "...", "destinations": ["id", ...]}
  /// Answers {"estimates": {"library": 2, "ai_lab": 3}} (walking minutes).
  /// Used for the "2 min walk" labels. Places with no route are left out.
  Future<Map<String, int>> getEstimates({
    required String start,
    required List<String> destinations,
  }) async {
    if (useMock) {
      await Future.delayed(const Duration(milliseconds: 250));
      final result = <String, int>{};
      for (final id in destinations) {
        try {
          final route = MockCampus.buildRoute(startId: start, destinationId: id);
          result[id] = math.max(1, route.minutes.round());
        } on ArgumentError {
          // No route to this place: leave it out.
        }
      }
      return result;
    }

    final data = await _send(() => http.post(
      Uri.parse('$baseUrl/api/estimates'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'start': start, 'destinations': destinations}),
    ));
    final raw = data is Map ? (data['estimates'] ?? data) : null;
    if (raw is! Map) {
      throw const ApiException('The server sent data the app could not read.');
    }
    return {
      for (final entry in raw.entries)
        entry.key.toString():
            math.max(1, (double.tryParse(entry.value.toString()) ?? 1).round()),
    };
  }

  /// POST /api/report   {"start", "destination", "reason", "details"}
  /// Lets a student say a route or location is wrong.
  /// "Report a problem": the backend files it for the team (a GitHub issue).
  /// [step]: the instruction being followed when it went wrong, if any.
  ///
  /// Returns true when it was sent, false when the phone is offline: then it
  /// is kept on the phone and sent later ([sendPendingReports]). Other
  /// failures throw an [ApiException] to show.
  Future<bool> reportProblem({
    required String start,
    required String destination,
    required String reason,
    String details = '',
    String? step,
    bool stepFree = false,
  }) async {
    final report = <String, dynamic>{
      'start': start,
      'destination': destination,
      'reason': reason,
      'details': details,
      if (step != null && step.isNotEmpty) 'step': step,
      if (stepFree) 'step_free': true,
    };
    if (useMock) {
      await Future.delayed(const Duration(milliseconds: 600));
      return true;
    }
    try {
      await _postReport(report);
      unawaited(sendPendingReports()); // online again: older ones too
      return true;
    } on ApiException catch (e) {
      if (e.kind != ApiErrorKind.offline && e.kind != ApiErrorKind.timeout) rethrow;
      await _queueReport(report);
      return false;
    }
  }

  Future<void> _postReport(Map<String, dynamic> report) => _send(() => http.post(
        Uri.parse('$baseUrl/api/report'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(report),
      ));

  static const _pendingKey = 'reports.pending';
  static const _maxPending = 20;
  static bool _sendingPending = false;

  Future<void> _queueReport(Map<String, dynamic> report) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_pendingKey) ?? <String>[];
      list.add(jsonEncode(report));
      while (list.length > _maxPending) {
        list.removeAt(0); // keep the newest
      }
      await prefs.setStringList(_pendingKey, list);
    } catch (_) {
      // No storage: nothing more to do.
    }
  }

  /// Sends the reports kept while offline (called when the app opens and
  /// after a report goes through). Stops at the first one that still cannot
  /// get through; drops one the server refuses, so none is stuck for ever.
  static Future<void> sendPendingReports() async {
    if (useMock || _sendingPending) return;
    _sendingPending = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      var list = prefs.getStringList(_pendingKey) ?? <String>[];
      while (list.isNotEmpty) {
        try {
          final report = jsonDecode(list.first);
          if (report is Map<String, dynamic>) await const ApiService()._postReport(report);
        } on ApiException catch (e) {
          if (e.kind == ApiErrorKind.offline || e.kind == ApiErrorKind.timeout) break;
        } catch (_) {
          // Unreadable: drop it.
        }
        list = list.sublist(1);
        await prefs.setStringList(_pendingKey, list);
      }
    } catch (_) {
      // Storage unavailable: try again next time.
    } finally {
      _sendingPending = false;
    }
  }

  /// Runs a request with a timeout and turns every failure into an
  /// [ApiException] the UI can show.
  Future<dynamic> _send(Future<http.Response> Function() request, {Duration? timeout}) async {
    await wakeUp(); // a sleeping server: wait for it rather than time out
    try {
      final response = await request().timeout(timeout ?? _timeout);
      _lastAnswer = DateTime.now();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _errorFrom(response);
      }
      // Some endpoints (like /api/report) may answer with an empty body.
      return response.body.isEmpty ? null : jsonDecode(response.body);
    } on TimeoutException {
      throw const ApiException(
          'The server took too long to answer. Check the Wi-Fi and try again.', ApiErrorKind.timeout);
    } on ApiException {
      rethrow;
    } on FormatException {
      throw const ApiException('The server sent data the app could not read.');
    } catch (_) {
      throw const ApiException(
          'Could not reach the server. Check that you are online (campus Wi-Fi or data).',
          ApiErrorKind.offline);
    }
  }

  /// Flask errors look like {"error": {"code": "...", "message": "..."}}.
  /// Turn them into something a student can act on. Newer backends write a
  /// friendly sentence ("X can only be reached by stairs ..."); use it then.
  ApiException _errorFrom(http.Response response) {
    String? code;
    String? serverText;
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['error'] is Map) {
        code = body['error']['code']?.toString();
        serverText = body['error']['message']?.toString();
      }
    } catch (_) {
      // Not JSON: fall through to the generic message.
    }
    // A sentence written for people starts with a capital letter.
    final friendly = serverText != null &&
            serverText.length > 12 &&
            serverText[0] == serverText[0].toUpperCase() &&
            serverText[0] != serverText[0].toLowerCase()
        ? serverText
        : null;
    final lower = '${code ?? ''} ${serverText ?? ''}'.toLowerCase();

    if (code == 'no_route' || lower.contains('step_free') || lower.contains('stairs')) {
      return ApiException(
        friendly ?? 'There is no walking route to this place from where you are.',
        ApiErrorKind.noRoute,
      );
    }
    switch (code) {
      case 'off_campus':
        return const ApiException(
          'You seem to be outside the campus paths. Pick a start point on campus.',
          ApiErrorKind.offCampus,
        );
      case 'rate_limited':
        return const ApiException(
          'Too many requests at once. Wait a moment and try again.',
          ApiErrorKind.rateLimited,
        );
      case 'not_found':
        return ApiException(
          friendly ?? 'The app does not know that place or start point. Try another start.',
          ApiErrorKind.notFound,
        );
      default:
        return ApiException(
          friendly ?? 'The server had a problem (${response.statusCode}). Try again in a moment.',
        );
    }
  }
}

/// The server has no /api/graph (an older backend).
class _NoGraph implements Exception {
  const _NoGraph();
}
