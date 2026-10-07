import 'package:flutter/foundation.dart';

import '../data/mock_campus.dart';
import '../models/start_point.dart';

/// State that more than one screen needs.
///
/// A ValueNotifier is Flutter's simplest "observable value": widgets wrapped
/// in a ValueListenableBuilder rebuild whenever `.value` changes.
class AppState {
  AppState._();

  static final ValueNotifier<StartPoint> startPoint =
      ValueNotifier<StartPoint>(MockCampus.startPoints.first);
}
