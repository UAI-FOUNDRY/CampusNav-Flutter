import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:campus_navigation/services/api_service.dart';

/// A fake backend: answers /api/health, records reports, or is unreachable.
class FakeServer {
  bool online = true;
  final reports = <Map<String, dynamic>>[];

  MockClient get client => MockClient((req) async {
        if (!online) throw const SocketException('no network');
        if (req.url.path == '/api/health') return http.Response('{"status":"ok"}', 200);
        if (req.url.path == '/api/report') {
          reports.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response('{"status":"received"}', 201);
        }
        return http.Response('{}', 404);
      });
}

Future<List<String>> pending() async =>
    (await SharedPreferences.getInstance()).getStringList('reports.pending') ?? const [];

void main() {
  setUp(() {
    ApiService.useMock = false;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => ApiService.useMock = true);

  test('a report sent online goes straight to the backend, with the step', () async {
    final server = FakeServer();
    final sent = await http.runWithClient(
      () => const ApiService().reportProblem(
        start: 'gate_main',
        destination: 'library',
        reason: 'The path was blocked',
        step: 'Turn right at Lobby',
        stepFree: true,
      ),
      () => server.client,
    );
    expect(sent, isTrue);
    expect(server.reports.single['step'], 'Turn right at Lobby');
    expect(server.reports.single['step_free'], isTrue);
    expect(await pending(), isEmpty);
  });

  test('offline it is kept on the phone, and sent once online again', () async {
    final server = FakeServer()..online = false;
    final sent = await http.runWithClient(
      () => const ApiService().reportProblem(start: 'gate_main', destination: 'library', reason: 'Door locked'),
      () => server.client,
    );
    expect(sent, isFalse);
    expect(await pending(), hasLength(1));

    // Still offline: it stays.
    await http.runWithClient(ApiService.sendPendingReports, () => server.client);
    expect(await pending(), hasLength(1));

    server.online = true;
    await http.runWithClient(ApiService.sendPendingReports, () => server.client);
    expect(server.reports.single['reason'], 'Door locked');
    expect(await pending(), isEmpty);
  });
}
