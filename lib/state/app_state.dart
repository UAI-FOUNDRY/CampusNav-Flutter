import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/campus.dart';
import '../models/start_point.dart';

/// State that more than one screen needs, saved on the phone.
///
/// A ValueNotifier is Flutter's simplest "observable value": widgets wrapped
/// in a ValueListenableBuilder rebuild whenever `.value` changes.
class AppState {
  AppState._();

  static final ValueNotifier<StartPoint> startPoint =
      ValueNotifier<StartPoint>(Campus.startPoints.first);
  static final ValueNotifier<bool> stepFree = ValueNotifier<bool>(false);
  static final ValueNotifier<List<String>> favorites =
      ValueNotifier<List<String>>(const []);
  static final ValueNotifier<List<String>> recents =
      ValueNotifier<List<String>>(const []);

  /// Start points picked recently (not GPS), most recent first.
  static final ValueNotifier<List<StartPoint>> recentStarts =
      ValueNotifier<List<StartPoint>>(const []);

  /// Recent trips as "startId>destinationId", most recent first.
  static final ValueNotifier<List<String>> trips =
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
    trips.value = prefs.getStringList('trips') ?? const [];
    // Step-free used to be one app-wide switch; it is now chosen per route
    // (NavigationScreen) and always starts off. Forget the old saved value.
    stepFree.value = false;
    prefs.remove('stepFree');

    recentStarts.value = (prefs.getStringList('recentStarts') ?? const <String>[])
        .map(_decode)
        .whereType<StartPoint>()
        .toList();

    final startId = prefs.getString('startId');
    if (startId == null) {
      firstRun = true;
    } else {
      // Any place or spot can be the start now, so its name is saved too.
      final name = prefs.getString('startName');
      final hint = prefs.getString('startHint') ?? '';
      var restored = name == null ? null : StartPoint(id: startId, name: name, hint: hint);
      for (final point in Campus.startPoints) {
        if (point.id == startId && name == null) restored = point;
      }
      if (restored != null) startPoint.value = restored;
    }
  }

  static StartPoint? _decode(String line) {
    final parts = line.split('\t');
    if (parts.length < 3 || parts[0].isEmpty) return null;
    return StartPoint(id: parts[0], name: parts[1], hint: parts[2], type: parts.length > 3 ? parts[3] : 'place');
  }

  static String _encode(StartPoint p) => [p.id, p.name, p.hint, p.type].join('\t');

  static void setStart(StartPoint point) {
    startPoint.value = point;
    // A GPS start is saved as the spot it was near: the exact position is
    // stale by the next time the app opens.
    _prefs?.setString('startId', point.id);
    _prefs?.setString('startName', point.live ? point.hint.split(' · ').first : point.name);
    _prefs?.setString('startHint', point.live ? 'Last GPS position' : point.hint);

    if (!point.live) {
      final list = [point, ...recentStarts.value.where((p) => p.id != point.id)].take(4).toList();
      recentStarts.value = list;
      _prefs?.setStringList('recentStarts', [for (final p in list) _encode(p)]);
    }
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

  /// Remembers a trip so it can be repeated in one tap. Keeps the last five.
  static void addTrip(String startId, String destinationId) {
    final trip = '$startId>$destinationId';
    final list = [...trips.value]..remove(trip);
    list.insert(0, trip);
    if (list.length > 5) list.removeRange(5, list.length);
    trips.value = list;
    _prefs?.setStringList('trips', list);
  }

  static void clearTrips() {
    trips.value = const [];
    _prefs?.remove('trips');
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
