import 'dart:async';
import 'dart:convert';

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

  /// GET /api/search?q=...   (an empty query returns every destination)
  Future<List<Destination>> searchDestinations([String query = '']) async {
    if (useMock) {
      await Future.delayed(const Duration(milliseconds: 700));
      return MockCampus.search(query);
    }

    final uri = Uri.parse('$baseUrl/api/search').replace(queryParameters: {'q': query});
    final data = await _send(http.get(uri));

    // Accept either a plain list or {"results": [...]}.
    final list = data is List
        ? data
        : (data is Map && data['results'] is List ? data['results'] as List : <dynamic>[]);
    return list
        .map((item) => Destination.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  /// POST /api/route   {"start": "...", "destination": "...", "step_free": false}
  Future<NavigationRoute> getRoute({
    required String start,
    required String destination,
    bool stepFree = false,
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

    final uri = Uri.parse('$baseUrl/api/route');
    final data = await _send(http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'start': start,
        'destination': destination,
        'step_free': stepFree,
      }),
    ));
    if (data is! Map) {
      throw const ApiException('The server sent data the app could not read.');
    }
    return NavigationRoute.fromJson(Map<String, dynamic>.from(data));
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
        throw ApiException('The server answered with an error (${response.statusCode}).');
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
}
