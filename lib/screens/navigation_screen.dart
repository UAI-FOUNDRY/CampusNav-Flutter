import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../data/mock_campus.dart';
import '../models/destination.dart';
import '../models/route.dart';
import '../models/start_point.dart';
import '../services/api_service.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import '../widgets/app_card.dart';
import '../widgets/campus_map.dart';
import '../widgets/floor_plan.dart';
import '../widgets/floor_selector.dart';
import '../widgets/map_frame.dart';
import '../widgets/pill.dart';
import '../widgets/route_strip.dart';
import '../widgets/segment_toggle.dart';
import '../widgets/state_views.dart';

/// Shows the route to one destination.
///
/// Three stages: overview (steps or map) -> guidance (one step at a time,
/// simulated until real positioning exists) -> arrival.
class NavigationScreen extends StatefulWidget {
  final Destination destination;

  const NavigationScreen({super.key, required this.destination});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final _api = const ApiService();

  // Where the user was when they opened this screen.
  late final StartPoint _start = AppState.startPoint.value;

  NavigationRoute? _route;
  String? _error;
  bool _loading = true;

  int _tab = 0; // 0 = steps, 1 = map
  int _planFloor = 0; // floor shown on the indoor plan
  bool _guiding = false;
  bool _arrived = false;
  int _stepIndex = 0;

  Color get _line => lineColorForBuilding(widget.destination.building);

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final route = await _api.getRoute(
        start: _start.id,
        destination: widget.destination.id,
      );
      if (!mounted) return;
      setState(() {
        _route = route;
        _loading = false;
        _error = null;
        _planFloor = route.targetFloor ?? 0;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _fetch();
  }

  // ---------------------------------------------------------------- guidance

  void _startGuidance(NavigationRoute route) {
    setState(() {
      _guiding = true;
      _stepIndex = math.min(1, route.steps.length - 1); // step 0 is "you are here"
    });
  }

  void _next(NavigationRoute route) {
    if (_stepIndex >= route.steps.length - 1) {
      setState(() => _arrived = true);
    } else {
      setState(() => _stepIndex++);
    }
  }

  void _previous() {
    if (_stepIndex > 1) setState(() => _stepIndex--);
  }

  void _endGuidance() {
    setState(() {
      _guiding = false;
      _stepIndex = 0;
    });
  }

  double _remainingMeters(NavigationRoute route) {
    var sum = 0.0;
    for (var i = _stepIndex; i < route.steps.length; i++) {
      sum += route.steps[i].distance ?? 0;
    }
    return sum;
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.destination.name),
        actions: [
          if (_guiding && !_arrived)
            TextButton(onPressed: _endGuidance, child: const Text('End')),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    final route = _route;
    if (_loading) {
      return const Padding(padding: EdgeInsets.all(20), child: LoadingList());
    }
    if (_error != null || route == null) {
      return ErrorView(message: _error ?? 'No route found.', onRetry: _retry);
    }
    if (_arrived) {
      return _ArrivalView(destination: widget.destination);
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            children: _guiding ? _guidanceContent(route) : _overviewContent(route),
          ),
        ),
        _bottomBar(route),
      ],
    );
  }

  // ---------------------------------------------------------------- overview

  List<Widget> _overviewContent(NavigationRoute route) {
    final text = Theme.of(context).textTheme;
    final minutes = math.max(1, route.minutes.round());
    final d = widget.destination;

    return [
      Text(
        'From ${_start.name}',
        style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
      ),
      const SizedBox(height: 14),
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('${route.distance.round()}', style: text.displaySmall),
          const SizedBox(width: 4),
          Text('m', style: text.titleLarge?.copyWith(color: AppColors.inkMuted)),
          const SizedBox(width: 16),
          Text(
            'about $minutes min',
            style: text.titleMedium?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Pill(text: d.building, color: _line),
          Pill(text: floorLabel(d.floor), color: _line, icon: Icons.layers_outlined),
        ],
      ),
      const SizedBox(height: 22),
      SegmentToggle(
        labels: const ['Steps', 'Map'],
        selected: _tab,
        onChanged: (i) => setState(() => _tab = i),
      ),
      const SizedBox(height: 22),
      if (_tab == 0)
        RouteStrip(steps: route.steps, lineColor: _line)
      else
        ..._mapContent(route, text),
    ];
  }

  List<Widget> _mapContent(NavigationRoute route, TextTheme text) {
    final building = MockCampus.buildingNamed(widget.destination.building);
    final plan = MockCampus.floorPlans[widget.destination.building];
    final target = route.targetFloor ?? widget.destination.floor;

    return [
      MapFrame(
        aspectRatio: MockCampus.canvasWidth / MockCampus.canvasHeight,
        child: CampusMap(
          routePath: route.path,
          routeColor: _line,
          startNodeId: _start.id,
          highlightBuilding: widget.destination.building,
        ),
      ),
      const SizedBox(height: 22),
      if (plan != null && building != null) ...[
        Text('Inside ${building.name}', style: text.titleMedium),
        const SizedBox(height: 12),
        FloorSelector(
          floors: [for (var f = 0; f <= target; f++) f],
          selected: _planFloor,
          color: _line,
          onChanged: (f) => setState(() => _planFloor = f),
        ),
        const SizedBox(height: 12),
        MapFrame(
          aspectRatio: MockCampus.indoorWidth / MockCampus.indoorHeight,
          child: FloorPlan(
            rooms: plan[_planFloor] ?? const [],
            floor: _planFloor,
            targetFloor: target,
            targetRoomId: widget.destination.id,
            connectorType: route.connectorType,
            color: _line,
          ),
        ),
      ] else
        AppCard(
          child: Row(
            children: [
              const Icon(Icons.layers_outlined, color: AppColors.inkMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'The indoor plan for ${widget.destination.building} is coming soon. '
                  'Follow the steps once you are inside.',
                  style: text.bodyMedium,
                ),
              ),
            ],
          ),
        ),
    ];
  }

  // ---------------------------------------------------------------- guidance

  List<Widget> _guidanceContent(NavigationRoute route) {
    final text = Theme.of(context).textTheme;
    final step = route.steps[_stepIndex];
    final remaining = _remainingMeters(route);
    final progress = _stepIndex / (route.steps.length - 1);

    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('${remaining.round()}', style: text.displaySmall),
          const SizedBox(width: 4),
          Text('m left', style: text.titleMedium?.copyWith(color: AppColors.inkMuted)),
        ],
      ),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 8,
          color: _line,
          backgroundColor: AppColors.mist,
        ),
      ),
      const SizedBox(height: 20),
      _CurrentStepCard(
        step: step,
        line: _line,
        index: _stepIndex,
        total: route.steps.length - 1,
      ),
      const SizedBox(height: 28),
      Text('Whole route', style: text.titleMedium),
      const SizedBox(height: 16),
      RouteStrip(steps: route.steps, lineColor: _line, currentIndex: _stepIndex),
    ];
  }

  Widget _bottomBar(NavigationRoute route) {
    final onLine = readableOnLine(_line);
    final buttonStyle = FilledButton.styleFrom(
      backgroundColor: _line,
      foregroundColor: onLine,
    );
    final atEnd = _stepIndex >= route.steps.length - 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.mist)),
      ),
      child: _guiding
          ? Row(
              children: [
                if (_stepIndex > 1) ...[
                  OutlinedButton(
                    onPressed: _previous,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(56, 56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: FilledButton(
                    style: buttonStyle,
                    onPressed: () => _next(route),
                    child: Text(atEnd ? "I've arrived" : 'Next step'),
                  ),
                ),
              ],
            )
          : FilledButton.icon(
              style: buttonStyle,
              onPressed: () => _startGuidance(route),
              icon: const Icon(Icons.navigation),
              label: const Text('Start navigation'),
            ),
    );
  }
}

/// The big coloured card showing the current instruction.
class _CurrentStepCard extends StatelessWidget {
  final RouteStep step;
  final Color line;
  final int index;
  final int total;

  const _CurrentStepCard({
    required this.step,
    required this.line,
    required this.index,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final onColor = readableOnLine(line);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: line,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: onColor.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(iconForStep(step.type), color: onColor, size: 30),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Step $index of $total',
                  style: text.bodySmall?.copyWith(color: onColor.withValues(alpha: 0.8)),
                ),
                const SizedBox(height: 2),
                Text(step.title, style: text.headlineSmall?.copyWith(color: onColor)),
                if (step.instruction.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(step.instruction, style: text.bodyMedium?.copyWith(color: onColor)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ArrivalView extends StatelessWidget {
  final Destination destination;

  const _ArrivalView({required this.destination});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: const BoxDecoration(
                color: AppColors.success,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check, size: 56, color: Colors.white),
            ),
            const SizedBox(height: 28),
            Text("You've arrived", style: text.headlineSmall),
            const SizedBox(height: 8),
            Text(destination.name, style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${destination.building}, ${floorLabel(destination.floor)}',
              style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
