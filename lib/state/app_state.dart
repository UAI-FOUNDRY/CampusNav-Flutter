import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/mock_campus.dart';
import '../models/start_point.dart';

/// State that more than one screen needs, saved on the phone.
///
/// A ValueNotifier is Flutter's simplest "observable value": widgets wrapped
/// in a ValueListenableBuilder rebuild whenever `.value` changes.
class AppState {
  AppState._();

  static final ValueNotifier<StartPoint> startPoint =
      ValueNotifier<StartPoint>(MockCampus.startPoints.first);
  static final ValueNotifier<bool> stepFree = ValueNotifier<bool>(false);
  static final ValueNotifier<List<String>> favorites =
      ValueNotifier<List<String>>(const []);
  static final ValueNotifier<List<String>> recents =
      ValueNotifier<List<String>>(const []);

  /// True until the user has chosen a start location once.
  static bool firstRun = false;

  static SharedPreferences? _prefs;

  /// Call once from main() before runApp().
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    favorites.value = prefs.getStringList('favorites') ?? const [];
    recents.value = prefs.getStringList('recents') ?? const [];
    stepFree.value = prefs.getBool('stepFree') ?? false;

    final startId = prefs.getString('startId');
    if (startId == null) {
      firstRun = true;
    } else {
      for (final point in MockCampus.startPoints) {
        if (point.id == startId) startPoint.value = point;
      }
    }
  }

  static void setStart(StartPoint point) {
    startPoint.value = point;
    _prefs?.setString('startId', point.id);
  }

  static void setStepFree(bool value) {
    stepFree.value = value;
    _prefs?.setBool('stepFree', value);
  }

  static void toggleFavorite(String id) {
    final list = [...favorites.value];
    if (list.contains(id)) {
      list.remove(id);
    } else {
      list.insert(0, id);
    }
    favorites.value = list;
    _prefs?.setStringList('favorites', list);
  }

  /// Most recent first, no duplicates, at most six.
  static void addRecent(String id) {
    final list = [...recents.value]..remove(id);
    list.insert(0, id);
    if (list.length > 6) list.removeRange(6, list.length);
    recents.value = list;
    _prefs?.setStringList('recents', list);
  }
}
