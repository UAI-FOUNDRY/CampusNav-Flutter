import '../models/start_point.dart';
import '../services/api_service.dart';
import 'live_campus.dart';
import 'mock_campus.dart';

/// One place to ask "where can the user start?", so screens do not care
/// whether the app is running on demo data or on the Flask backend.
class Campus {
  Campus._();

  static List<StartPoint> get startPoints =>
      ApiService.useMock ? MockCampus.startPoints : LiveCampus.startPoints;

  static StartPoint? startPointFromCode(String raw) => ApiService.useMock
      ? MockCampus.startPointFromCode(raw)
      : LiveCampus.startPointFromCode(raw);
}
