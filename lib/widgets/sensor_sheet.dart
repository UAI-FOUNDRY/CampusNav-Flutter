import 'dart:async';

import 'package:flutter/material.dart';

import '../services/floor_barometer.dart';
import '../services/live_guide.dart';
import '../services/motion_sensors.dart';
import '../services/wifi_fingerprints.dart';
import '../theme/app_colors.dart';

/// What every sensor is doing during live guidance, and the floor
/// calibration. Opened from the status line of the guidance panel.
Future<void> showSensorSheet(BuildContext context, {required LiveGuide guide}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.platform,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => _SensorSheet(guide: guide, scroll: scroll),
    ),
  );
}

class _SensorSheet extends StatefulWidget {
  final LiveGuide guide;
  final ScrollController scroll;

  const _SensorSheet({required this.guide, required this.scroll});

  @override
  State<_SensorSheet> createState() => _SensorSheetState();
}

class _SensorSheetState extends State<_SensorSheet> {
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    // Readings change all the time: redraw twice a second.
    _refresh = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
    unawaited(WifiFingerprints.instance.load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  static String _ago(DateTime? t) {
    if (t == null) return 'never';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }

  static String _floorName(int f) => f == 0 ? 'ground floor' : 'floor $f';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final g = widget.guide;
    final baro = FloorBarometer.instance;
    final wifi = WifiFingerprints.instance;
    final pose = g.pose.value;
    final fix = g.lastFix;
    final route = g.route;

    final fixAge = fix == null ? null : DateTime.now().difference(fix.timestamp).inSeconds;
    final gpsText = fix == null
        ? (g.gpsProblem?.message ?? 'Waiting for the first fix')
        : '±${fix.accuracy.round()} m · ${(fix.speed < 0 ? 0 : fix.speed).toStringAsFixed(1)} m/s'
            '${fixAge != null && fixAge > 3 ? ' · ${fixAge}s old' : ''}';
    final p = baro.pressure.value;
    final est = baro.estimate();
    final floorText = !baro.available
        ? 'This phone has no barometer. On the stairs your steps are counted '
            '(${g.stairStepsPerFloor.round()} a floor, learned for your stairs from your walking '
            'rhythm); the lift is felt starting and stopping. On Android the Wi-Fi around also '
            'tells the floor once it has been learned'
        : p == null
            ? 'Waiting for a reading'
            : est == null
                ? '${p.toStringAsFixed(2)} hPa · floor changes are still counted; '
                    'the exact floor needs a reference (set it below)'
                : '${p.toStringAsFixed(2)} hPa · ${_floorName(est.floor)} '
                    '(${(est.confidence * 100).round()} % sure, level ${est.level.toStringAsFixed(2)})';
    final metresPerFloor = baro.hPaPerFloor / FloorBarometer.hPaPerMetre;
    final heading = g.compassHeading;

    final floors = <int>{0, 1, 2, for (final l in route.legs) if (l.isIndoor) l.floor}.toList()..sort();

    Widget row(IconData icon, String title, String value, {bool ok = true}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: (ok ? AppColors.success : AppColors.inkMuted).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: ok ? AppColors.success : AppColors.inkMuted),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleSmall),
                    Text(value, style: text.bodySmall?.copyWith(color: AppColors.inkMuted)),
                  ],
                ),
              ),
            ],
          ),
        );

    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.inkMuted.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text('How the app follows you', style: text.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Every sensor helps: GPS outside, your steps and turns inside, air pressure for the floor.',
          style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
        ),
        const SizedBox(height: 12),
        row(
          Icons.route,
          'Position on the route',
          pose == null
              ? 'Starting…'
              : '${(pose.along * g.geometry.scale).round()} m of ${(g.geometry.length * g.geometry.scale).round()} m'
                  ' · ±${g.positionSigma.toStringAsFixed(1)} m'
                  ' · ${pose.indoor ? 'inside, ${_floorName(pose.floor)}' : 'outside'}',
        ),
        row(Icons.gps_fixed, 'GPS', gpsText, ok: fix != null && fix.accuracy <= 25),
        row(
          Icons.directions_walk,
          'Steps (accelerometer, works on every phone)',
          g.hasStepSensor
              ? '${g.stepCount} steps · step length ${g.stepLength.toStringAsFixed(2)} m (learned as you walk)'
              : 'No steps yet (or no step sensor)',
          ok: g.hasStepSensor,
        ),
        if (!g.hasBarometer)
          row(
            Icons.elevator_outlined,
            'Lift (accelerometer)',
            '${g.liftStatus}. The lift is felt starting and stopping; hold the phone '
                'still-ish in the lift for the best result',
            ok: g.hasStepSensor,
          ),
        row(
          Icons.rotate_right,
          'Turns (gyroscope)',
          g.hasGyroscope
              ? 'Corners you take are matched to the route to correct the distance'
              : heading != null
                  ? 'No gyroscope on this phone: turns are read from the compass instead '
                      '(less sure near steel); on stairs the step count decides'
                  : 'No gyroscope readings',
          ok: g.hasGyroscope || heading != null,
        ),
        row(
          Icons.explore_outlined,
          'Compass',
          heading == null ? 'No compass readings' : 'Phone points ${heading.round()}° (0° = north)',
          ok: heading != null,
        ),
        row(
          Icons.speed,
          'Barometer (floors)',
          '$floorText\nOne floor = ${baro.hPaPerFloor.toStringAsFixed(3)} hPa '
              '(about ${metresPerFloor.toStringAsFixed(1)} m, learned on stairs and lifts)'
              '${baro.hasReference ? '\nReference: ${baro.referenceBasis}, ${_ago(baro.referenceTime)}' : ''}',
          ok: baro.available && p != null,
        ),
        if (wifi.supported)
          row(
            Icons.wifi,
            'Wi-Fi fingerprints',
            '${wifi.spotCount} spots learned. Each spot you pick in "Where exactly are you?" '
                'or each sign you scan teaches the app that room.',
            ok: wifi.spotCount > 0,
          ),
        const SizedBox(height: 16),
        Text('Which floor are you on?', style: text.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Tap it once if the floor shown is wrong: the barometer uses it as its reference.',
          style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final f in floors)
              ActionChip(
                label: Text(f == 0 ? 'Ground' : 'Floor $f'),
                onPressed: p == null
                    ? null
                    : () {
                        baro.setFloor(f, basis: 'you');
                        if (pose != null && pose.indoor && pose.floor == f) g.dismissMismatch();
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          behavior: SnackBarBehavior.floating,
                          content: Text('Floor set: ${_floorName(f)}'),
                        ));
                      },
              ),
          ],
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Simulate the walk'),
          subtitle: const Text('For testing at a desk: walks the route at 1.3 m/s and takes the stairs by itself'),
          value: g.simulating,
          onChanged: (on) => setState(() => g.setSimulating(on)),
        ),
        const SizedBox(height: 4),
        Text(
          'Sensor time ${SensorClock.now().toStringAsFixed(0)} s',
          style: text.bodySmall?.copyWith(color: AppColors.inkMuted.withValues(alpha: 0.6)),
        ),
      ],
    );
  }
}
