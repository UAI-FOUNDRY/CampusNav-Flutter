import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../data/mock_campus.dart';
import '../models/destination.dart';
import '../models/route.dart';

/// An error with a message that is safe to show to the user.
class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => message;
}

/// The only place in the app that talks to the backend.
///
/// Run against demo data (default):
///   flutter run
/// Run against Flask:
///   flutter run --dart-define=USE_MOCK=false --dart-define=API_BASE_URL=http://192.168.1.10:5000
class ApiService {
  const ApiService();

  /// 10.0.2.2 is how the Android emulator reaches your laptop.
  /// On a real phone use your laptop's Wi-Fi IP address instead.
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:5000',
  );

  static const bool useMock = bool.fromEnvironment('USE_MOCK', defaultValue: true);

  static const Duration _timeout = Duration(seconds: 8);

  /// GET /api/rooms?q=...   (an empty query returns every place)
  Future<List<Destination>> searchDestinations([String query = '']) async {
    if (useMock) {
      await Future.delayed(const Duration(milliseconds: 700));
      return MockCampus.search(query);
    }

    // limit=50 is the backend's maximum; the campus has far fewer places.
    final uri = Uri.parse('$baseUrl/api/rooms')
        .replace(queryParameters: {'q': query, 'limit': '50'});
    final data = await _send(http.get(uri));

    // Flask answers {"results": [...]}; also accept a plain list.
    final list = data is List
        ? data
        : (data is Map && data['results'] is List ? data['results'] as List : <dynamic>[]);
    return list
        .map((item) => Destination.fromJson(Map<String, dynamic>.from(item as Map)))
        // Junction dots are in the place list but nobody searches for them.
        .where((d) => !d.name.toLowerCase().contains('junction'))
        .toList();
  }

  /// GET /api/route?from=<id>&to=<id>[&accessible=1]
  ///
  /// [startName] is only used to label the first step ("You are here").
  Future<NavigationRoute> getRoute({
    required String start,
    required String destination,
    bool stepFree = false,
    String? startName,
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
        throw const ApiException('No walking route was found for that place.');
      }
    }

    final uri = Uri.parse('$baseUrl/api/route').replace(queryParameters: {
      'from': start,
      'to': destination,
      if (stepFree) 'accessible': '1',
    });
    final data = await _send(http.get(uri));
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

    final data = await _send(http.post(
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
  Future<void> reportProblem({
    required String start,
    required String destination,
    required String reason,
    String details = '',
  }) async {
    if (useMock) {
      await Future.delayed(const Duration(milliseconds: 600));
      return;
    }
    await _send(http.post(
      Uri.parse('$baseUrl/api/report'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'start': start,
        'destination': destination,
        'reason': reason,
        'details': details,
      }),
    ));
  }

  /// Runs a request with a timeout and turns every failure into an
  /// [ApiException] the UI can show.
  Future<dynamic> _send(Future<http.Response> request) async {
    try {
      final response = await request.timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(_errorMessage(response));
      }
      // Some endpoints (like /api/report) may answer with an empty body.
      return response.body.isEmpty ? null : jsonDecode(response.body);
    } on TimeoutException {
      throw const ApiException('The server took too long to respond.');
    } on ApiException {
      rethrow;
    } on FormatException {
      throw const ApiException('The server sent data the app could not read.');
    } catch (_) {
      throw const ApiException('Could not reach the server. Check your connection.');
    }
  }

  /// Flask errors look like {"error": {"code": "...", "message": "..."}}.
  /// Turn the common ones into something a student can act on.
  String _errorMessage(http.Response response) {
    String? code;
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['error'] is Map) {
        code = body['error']['code']?.toString();
      }
    } catch (_) {
      // Not JSON: fall through to the generic message.
    }
    switch (code) {
      case 'no_route':
        return 'No walking route was found for that place.';
      case 'off_campus':
        return 'You seem to be too far from the campus paths.';
      case 'not_found':
        return 'The app does not know that place yet. Try another start point.';
      default:
        return 'The server answered with an error (${response.statusCode}).';
    }
  }
}
