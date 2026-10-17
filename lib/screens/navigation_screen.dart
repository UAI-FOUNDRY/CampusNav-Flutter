import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../widgets/live_floor_plan.dart';
import '../widgets/live_route_map.dart';
import '../widgets/map_frame.dart';
import '../widgets/pill.dart';
import '../widgets/report_sheet.dart';
import '../widgets/route_strip.dart';
import '../widgets/segment_toggle.dart';
import '../widgets/state_views.dart';
import '../widgets/zoomable_view.dart';

/// Shows the route to one destination.
///
/// Three stages: overview (steps or map) -> guidance (one step at a time,
/// simulated until real positioning exists) -> arrival.
class NavigationScreen extends StatefulWidget {
  final Destination destination;

  /// Where the trip starts. Defaults to the user's current location; "Recent
  /// trips" passes the trip's own start.
  final StartPoint? start;

  const NavigationScreen({super.key, required this.destination, this.start});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final _api = const ApiService();

  // Where the user was when they opened this screen.
  late final StartPoint _start = widget.start ?? AppState.startPoint.value;

  NavigationRoute? _route;
  String? _error;
  bool _loading = true;

  int _tab = 0; // 0 = steps, 1 = map
  int _planFloor = 0; // floor shown on the indoor plan
  bool _guiding = false;
  bool _arrived = false;
  int _stepIndex = 0;

  // "Simulate walk": a timer that moves to the next step by itself.
  Timer? _timer;
  bool _simulating = false;

  Color get _line => lineColorForBuilding(widget.destination.building);

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _timer?.cancel(); // a running timer must be stopped when the screen closes
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final route = await _api.getRoute(
        start: _start.id,
        destination: widget.destination.id,
        stepFree: AppState.stepFree.value,
        startName: _start.name,
      );
      if (!mounted) return;
      AppState.addRecent(widget.destination.id);
      AppState.addTrip(_start.id, widget.destination.id);
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
      HapticFeedback.mediumImpact();
      setState(() => _arrived = true);
    } else {
      HapticFeedback.selectionClick();
      setState(() => _stepIndex++);
    }
  }

  void _previous() {
    _stopSimulation();
    if (_stepIndex > 1) {
      HapticFeedback.selectionClick();
      setState(() => _stepIndex--);
    }
  }

  void _endGuidance() {
    _stopSimulation();
    setState(() {
      _guiding = false;
      _stepIndex = 0;
    });
  }

  void _toggleSimulation(NavigationRoute route) {
    if (_simulating) {
      _stopSimulation();
      return;
    }
    setState(() => _simulating = true);
    _timer = Timer.periodic(const Duration(milliseconds: 2800), (timer) {
      _next(route);
      if (_arrived) _stopSimulation();
    });
  }

  void _stopSimulation() {
    _timer?.cancel();
    _timer = null;
    if (mounted && _simulating) setState(() => _simulating = false);
  }

  double _remainingMeters(NavigationRoute route) {
    var sum = 0.0;
    for (var i = _stepIndex; i < route.steps.length; i++) {
      sum += route.steps[i].distance ?? 0;
    }
    return sum;
  }

  // ------------------------------------------------------------------- build

  /// Live guidance takes over the whole screen, like Google Maps.
  bool get _fullScreen =>
      !ApiService.useMock && _guiding && !_arrived && _route != null;

  @override
  Widget build(BuildContext context) {
    // The phone's back button ends navigation first instead of leaving the screen.
    return PopScope(
      canPop: !_guiding || _arrived,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _endGuidance();
      },
      child: _scaffold(),
    );
  }

  Widget _scaffold() {
    if (_fullScreen) {
      return Scaffold(body: _liveGuidance(_route!));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.destination.name),
        actions: [
          if (_guiding && !_arrived)
            TextButton(onPressed: _endGuidance, child: const Text('End')),
          ValueListenableBuilder<List<String>>(
            valueListenable: AppState.favorites,
            builder: (context, favorites, _) {
              final saved = favorites.contains(widget.destination.id);
              return IconButton(
                tooltip: saved ? 'Remove from saved' : 'Save this place',
                icon: Icon(
                  saved ? Icons.star : Icons.star_border,
                  color: saved ? AppColors.sports : null,
                ),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  AppState.toggleFavorite(widget.destination.id);
                },
              );
            },
          ),
          IconButton(
            tooltip: 'Report a problem',
            icon: const Icon(Icons.flag_outlined),
            onPressed: () => showReportSheet(
              context,
              destination: widget.destination,
              start: _start,
            ),
          ),
          const SizedBox(width: 4),
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
      if (d.floor > 0) ...[
        const SizedBox(height: 16),
        AppCard(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              const Icon(Icons.accessible, color: AppColors.inkMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Step-free route', style: text.titleMedium),
                    Text(
                      'Use the lift instead of stairs',
                      style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: AppState.stepFree,
                builder: (context, value, _) => Switch(
                  value: value,
                  onChanged: (v) {
                    AppState.setStepFree(v);
                    _retry(); // ask for a new route
                  },
                ),
              ),
            ],
          ),
        ),
      ],
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

  /// Map tab for a route from the real backend: the outdoor line on
  /// OpenStreetMap, then one floor plan per indoor leg.
  List<Widget> _liveMapContent(NavigationRoute route, TextTheme text) {
    final outdoor = route.outdoorPolyline;
    final indoor = route.indoorLegs;

    return [
      if (outdoor.length > 1) ...[
        Text('Outside', style: text.titleMedium),
        const SizedBox(height: 12),
        LiveCampusMap(route: outdoor, color: _line),
        const SizedBox(height: 22),
      ],
      for (final leg in indoor) ...[
        Text('Inside, ${floorLabel(leg.floor).toLowerCase()}', style: text.titleMedium),
        const SizedBox(height: 12),
        MapFrame(
          aspectRatio: leg.imageWidth / leg.imageHeight,
          zoomable: true,
          // Opens zoomed onto this leg instead of the whole floor.
          focus: routeFocus(leg.points, leg.imageWidth, leg.imageHeight),
          builder: (context, zoom) => LiveFloorPlan(
            image: leg.image!,
            imageWidth: leg.imageWidth,
            imageHeight: leg.imageHeight,
            route: leg.points,
            color: _line,
            zoom: zoom,
          ),
        ),
        const SizedBox(height: 22),
      ],
      if (outdoor.length <= 1 && indoor.isEmpty)
        AppCard(
          child: Text('There is no map for this route yet. Follow the steps.', style: text.bodyMedium),
        ),
    ];
  }

  List<Widget> _mapContent(NavigationRoute route, TextTheme text) {
    if (!ApiService.useMock) return _liveMapContent(route, text);
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

  /// Full-screen navigation: the map fills the screen, the instruction floats
  /// at the top and a panel with distance and buttons sits at the bottom.
  Widget _liveGuidance(NavigationRoute route) {
    final step = route.steps[_stepIndex];
    final top = MediaQuery.of(context).padding.top;

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _guidanceMap(route, step)),
              // A soft white fade so the phone's clock and battery stay readable.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: top + 24,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.9),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: top + 8,
                left: 12,
                right: 12,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, -0.15),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _TurnBanner(
                    key: ValueKey(_stepIndex),
                    step: step,
                    line: _line,
                    index: _stepIndex,
                    total: route.steps.length - 1,
                  ),
                ),
              ),
            ],
          ),
        ),
        _guidancePanel(route),
      ],
    );
  }

  /// The outdoor map while the current step is outside, the floor plan once
  /// it is inside. The person icon sits at the start of the current step and
  /// moves as you go to the next one.
  Widget _guidanceMap(NavigationRoute route, RouteStep step) {
    final inside = step.space == 'indoor';

    Widget child = const SizedBox.shrink();
    var key = 'outside';

    if (!inside) {
      final here = (step.lat != null && step.lng != null)
          ? GeoPoint(step.lat!, step.lng!)
          : null;
      child = LiveCampusMap(
        route: route.outdoorPolyline,
        color: _line,
        person: here,
        follow: true,
        fill: true,
      );
    } else {
      RouteLeg? found;
      for (final l in route.indoorLegs) {
        if (l.floor == (step.floor ?? 0)) {
          found = l;
          break;
        }
      }
      // final, so the null check below still holds inside the zoom builder.
      final leg = found;
      if (leg != null && step.x != null && step.y != null) {
        key = 'inside-${leg.floor}';
        child = Stack(
          children: [
            Positioned.fill(
              child: Container(
                color: AppColors.mapBackground,
                // Pinch or double-tap to zoom the floor plan, drag to move it.
                // Lines and the person icon keep their size on screen.
                child: ZoomableView(
                  builder: (context, zoom) => Center(
                    child: AspectRatio(
                      aspectRatio: leg.imageWidth / leg.imageHeight,
                      child: LiveFloorPlan(
                        image: leg.image!,
                        imageWidth: leg.imageWidth,
                        imageHeight: leg.imageHeight,
                        route: leg.points,
                        color: _line,
                        person: MapPoint(step.x!, step.y!),
                        zoom: zoom,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 12,
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.layers_outlined, size: 16, color: AppColors.ink),
                    const SizedBox(width: 6),
                    Text(
                      floorLabel(leg.floor),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }
    }

    // Fades between the outdoor map and the floor plan when you go inside.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: KeyedSubtree(
        key: ValueKey(key),
        child: SizedBox.expand(child: child),
      ),
    );
  }

  /// Bottom panel: distance and time left, progress, and the buttons.
  Widget _guidancePanel(NavigationRoute route) {
    final text = Theme.of(context).textTheme;
    final remaining = _remainingMeters(route);
    final progress = _stepIndex / (route.steps.length - 1);
    final atEnd = _stepIndex >= route.steps.length - 1;
    final bottom = MediaQuery.of(context).padding.bottom;
    final minutes = route.distance > 0
        ? math.max(1, (route.minutes * remaining / route.distance).round())
        : 1;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 14 + bottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(color: Color(0x26000000), blurRadius: 16, offset: Offset(0, -4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: remaining < 1
                    ? Text('Arriving', style: text.headlineSmall)
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          // The number counts down smoothly instead of jumping.
                          TweenAnimationBuilder<double>(
                            tween: Tween<double>(end: remaining),
                            duration: const Duration(milliseconds: 600),
                            curve: Curves.easeOut,
                            builder: (context, value, _) =>
                                Text('${value.round()}', style: text.headlineSmall),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            'm left',
                            style: text.titleMedium?.copyWith(color: AppColors.inkMuted),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '·  $minutes min',
                            style: text.titleMedium?.copyWith(color: AppColors.inkMuted),
                          ),
                        ],
                      ),
              ),
              TextButton(
                onPressed: _endGuidance,
                style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                child: const Text('End'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: progress),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOut,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 6,
                color: _line,
                backgroundColor: AppColors.mist,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
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
                  style: FilledButton.styleFrom(
                    backgroundColor: _line,
                    foregroundColor: readableOnLine(_line),
                  ),
                  onPressed: () {
                    _stopSimulation();
                    _next(route);
                  },
                  child: Text(atEnd ? "I've arrived" : 'Next step'),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                tooltip: _simulating ? 'Pause simulation' : 'Simulate walk',
                style: IconButton.styleFrom(minimumSize: const Size(56, 56)),
                onPressed: () => _toggleSimulation(route),
                icon: Icon(_simulating ? Icons.pause : Icons.play_arrow),
              ),
            ],
          ),
        ],
      ),
    );
  }

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
          // The number counts down smoothly instead of jumping.
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: remaining),
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOut,
            builder: (context, value, _) =>
                Text('${value.round()}', style: text.displaySmall),
          ),
          const SizedBox(width: 4),
          Text('m left', style: text.titleMedium?.copyWith(color: AppColors.inkMuted)),
        ],
      ),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: progress),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOut,
          builder: (context, value, _) => LinearProgressIndicator(
            value: value,
            minHeight: 8,
            color: _line,
            backgroundColor: AppColors.mist,
          ),
        ),
      ),
      const SizedBox(height: 20),
      // The key changes with every step, so AnimatedSwitcher slides the old
      // card out and the new one in.
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.12, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: _CurrentStepCard(
          key: ValueKey(_stepIndex),
          step: step,
          line: _line,
          index: _stepIndex,
          total: route.steps.length - 1,
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _toggleSimulation(route),
          icon: Icon(_simulating ? Icons.pause_circle_outline : Icons.play_circle_outline),
          label: Text(_simulating ? 'Pause simulation' : 'Simulate walk'),
        ),
      ),
      const SizedBox(height: 16),
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
                    onPressed: () {
                      _stopSimulation();
                      _next(route);
                    },
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

/// The instruction that floats over the map during navigation.
class _TurnBanner extends StatelessWidget {
  final RouteStep step;
  final Color line;
  final int index;
  final int total;

  const _TurnBanner({
    super.key,
    required this.step,
    required this.line,
    required this.index,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final onColor = readableOnLine(line);
    final metres = step.distance ?? 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
      decoration: BoxDecoration(
        color: line,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 14, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: onColor.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(iconForStep(step.type), color: onColor, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  step.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleLarge?.copyWith(color: onColor),
                ),
                if (step.instruction.isNotEmpty && step.instruction != step.title) ...[
                  const SizedBox(height: 2),
                  Text(
                    step.instruction,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(color: onColor.withValues(alpha: 0.92)),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'Step $index of $total',
                  style: text.bodySmall?.copyWith(color: onColor.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),
          if (metres >= 1) ...[
            const SizedBox(width: 12),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${metres.round()}',
                  style: text.headlineSmall?.copyWith(color: onColor),
                ),
                Text('m', style: text.bodySmall?.copyWith(color: onColor.withValues(alpha: 0.8))),
              ],
            ),
          ],
        ],
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
    super.key,
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
