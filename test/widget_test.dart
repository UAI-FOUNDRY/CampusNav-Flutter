import 'package:flutter_test/flutter_test.dart';

import 'package:campus_navigation/data/mock_campus.dart';
import 'package:campus_navigation/services/api_service.dart';
import 'package:campus_navigation/main.dart';

void main() {
  test('route from the gate to the AI Lab walks, goes inside and takes the stairs', () {
    final route = MockCampus.buildRoute(startId: 'gate_main', destinationId: 'ai_lab');

    expect(route.steps.first.type, 'start');
    expect(route.steps.last.type, 'arrive');
    expect(route.steps.any((s) => s.type == 'stairs'), isTrue);
    expect(route.targetFloor, 2);
    expect(route.distance, greaterThan(100));
  });

  test('starting at the destination building skips the outdoor walk', () {
    final route = MockCampus.buildRoute(startId: 'acad_entrance', destinationId: 'library');

    expect(route.path.length, 1);
    expect(route.steps.map((s) => s.type), ['start', 'enter', 'stairs', 'arrive']);
  });

  test('step-free routing uses the lift instead of the stairs', () {
    final route = MockCampus.buildRoute(
      startId: 'gate_main',
      destinationId: 'library',
      stepFree: true,
    );

    expect(route.connectorType, 'lift');
    expect(route.steps.any((s) => s.type == 'stairs'), isFalse);
  });

  test('QR codes become start points, unknown codes are rejected', () {
    expect(MockCampus.startPointFromCode('campusnav:acad_entrance')?.name, 'Academic Building');
    expect(MockCampus.startPointFromCode('north_junction')?.name, 'North Junction');
    expect(MockCampus.startPointFromCode('https://example.com'), isNull);
  });

  test('walking time estimates cover every reachable destination', () async {
    final estimates = await const ApiService().getEstimates(
      start: 'gate_main',
      destinations: ['library', 'ai_lab', 'nope'],
    );

    expect(estimates.keys, containsAll(['library', 'ai_lab']));
    expect(estimates.containsKey('nope'), isFalse);
    expect(estimates['library'], greaterThanOrEqualTo(1));
  });

  testWidgets('home screen loads the destinations', (tester) async {
    await tester.pumpWidget(const CampusNavApp());
    await tester.pump(const Duration(seconds: 1)); // wait for the mock delay

    expect(find.text('Where are you now?'), findsOneWidget);
    expect(find.text('Library'), findsWidgets);
  });
}
