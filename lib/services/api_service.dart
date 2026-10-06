import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/destination.dart';
import '../models/route.dart';

class ApiService {
  // ----------------------------------------------------------
  // BACKEND BASE URL
  // ----------------------------------------------------------

  // Temporary placeholder.
  //
  // Your backend teammate will eventually give you
  // the actual URL.
  static const String baseUrl = 'http://YOUR_BACKEND_URL';

  // ----------------------------------------------------------
  // SEARCH DESTINATIONS
  // ----------------------------------------------------------

  Future<List<Destination>> searchDestinations(
    String query,
  ) async {
    final uri = Uri.parse(
      '$baseUrl/api/search?q=${Uri.encodeComponent(query)}',
    );

    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to search destinations: '
        '${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body);

    final List results = data as List;

    return results
        .map(
          (item) => Destination.fromJson(
            Map<String, dynamic>.from(item),
          ),
        )
        .toList();
  }

  // ----------------------------------------------------------
  // GET ROUTE
  // ----------------------------------------------------------

  Future<NavigationRoute> getRoute({
    required String start,
    required String destination,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/api/route',
    );

    final response = await http.post(
      uri,

      headers: {
        'Content-Type': 'application/json',
      },

      body: jsonEncode({
        'start': start,
        'destination': destination,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to get route: '
        '${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body);

    return NavigationRoute.fromJson(
      Map<String, dynamic>.from(data),
    );
  }
}