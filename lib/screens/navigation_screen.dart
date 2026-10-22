import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../data/mock_campus.dart';
import '../models/destination.dart';
import '../models/route.dart';
import '../models/start_point.dart';
import '../services/api_service.dart';
import '../services/live_guide.dart';
import '../services/location_service.dart';
import '../services/spot_locator.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import '../widgets/app_card.dart';
import '../widgets/campus_map.dart';
import '../widgets/floor_plan.dart';
import '../widgets/floor_plan_viewer.dart';
import '../widgets/floor_selector.dart';
import '../widgets/live_floor_plan.dart';
import '../widgets/live_route_map.dart';
import '../widgets/map_frame.dart';
import '../widgets/pill.dart';
import '../widgets/report_sheet.dart';
import '../widgets/route_strip.dart';
import '../widgets/segment_toggle.dart';
import '../widgets/sensor_sheet.dart';
import '../widgets/start_location_sheet.dart';
import '../widgets/state_views.dart';
import 'route_map_screen.dart';
import 'scan_screen.dart';

/// Shows the route to one destination.
///
/// Three stages: overview (steps or map) -> guidance (one step at a time,
/// followed by GPS outside, Next / QR signs inside) -> arrival.
class NavigationScreen extends StatefulWidget {
  final Destination destination;

  /// Where the trip starts. Defaults to the user's current location; "Recent
  /// trips" passes the trip's own start.
  final StartPoint? start;

  const NavigationScreen({super.key, required this.destination, this.start});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen>
    with SingleTickerProviderStateMixin {
  final _api = const ApiService();

  // Where the user was when they opened this screen.
  late StartPoint _start = widget.start ?? AppState.startPoint.value;

  // "Change" on the From row (or on an error) opens the start sheet; when the
  // start changes, this route is fetched again from the new start.
  bool _waitingForStart = false;

  // Guidance: the stairs/lift moment gets its own full card, confirmed by
  // the user, because that is where people get lost.
  _FloorPrompt? _floorPrompt;

  NavigationRoute? _route;
  String? _error;
  ApiErrorKind _errorKind = ApiErrorKind.server;
  bool _loading = true;

  // Step-free is chosen per route and starts off every time; turning it on
  // asks for a lift/ramp route. Some places can only be reached by stairs,
  // so when there is none we keep the normal route and say so.
  bool _stepFree = false;
  bool _stepFreeBusy = false;
  bool _noStepFreeRoute = false;

  int _tab = 0; // 0 = steps, 1 = map
  int _planFloor = 0; // floor shown on the indoor plan
  bool _guiding = false;
  bool _arrived = false;
  int _stepIndex = 0;

  // ---- live guidance ----
  // GPS outside, steps + turns inside, the barometer for floors, the compass
  // for which way you face (see LiveGuide). It moves the person icon every
  // frame, moves on to the next step by itself, closes the stairs / lift
  // card when you reach the floor and finds a new route if you go off the
  // path. Without it (demo data) you tap Next as you go.
  LiveGuide? _guide;
  Ticker? _frames;
  bool _rerouting = false;
  DateTime? _lastReroute;

  /// The route is drawn in the colour of the place's line (labs purple,
  /// food red ...), like a metro line.
  Color get _line => ApiService.useMock
      ? lineColorForBuilding(widget.destination.building)
      : colorForType(widget.destination.type);

  @override
  void initState() {
    super.initState();
    AppState.startPoint.addListener(_onStartChanged);
    _fetch();
  }

  @override
  void dispose() {
    AppState.startPoint.removeListener(_onStartChanged);
    _stopLive(); // sensors and GPS off when the screen closes
    _frames?.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final route = await _api.getRoute(
        start: _start.id,
        destination: widget.destination.id,
        stepFree: _stepFree,
        startName: _start.name,
        // "My location": start exactly where the phone is.
        startLat: _start.live ? _start.lat : null,
        startLng: _start.live ? _start.lng : null,
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
        _errorKind = e.kind;
        _loading = false;
      });
    }
  }

  void _changeStart() {
    _waitingForStart = true;
    showStartLocationSheet(context);
  }

  void _onStartChanged() {
    if (!_waitingForStart || !mounted) return;
    _waitingForStart = false;
    setState(() {
      _start = AppState.startPoint.value;
      _loading = true;
      _error = null;
      _stepFree = false;
      _noStepFreeRoute = false;
    });
    _fetch();
  }

  /// The step-free switch: fetch the other kind of route but keep showing the
  /// current one until it arrives. If there is no step-free route, switch
  /// back off, keep the normal route and explain.
  Future<void> _setStepFree(bool on) async {
    setState(() {
      _stepFree = on;
      _stepFreeBusy = true;
    });
    try {
      final route = await _api.getRoute(
        start: _start.id,
        destination: widget.destination.id,
        stepFree: on,
        startName: _start.name,
        // "My location": start exactly where the phone is.
        startLat: _start.live ? _start.lat : null,
        startLng: _start.live ? _start.lng : null,
      );
      if (!mounted) return;
      setState(() {
        _route = route;
        _stepFreeBusy = false;
        _planFloor = route.targetFloor ?? 0;
        _stepIndex = 0;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _stepFree = false;
        _stepFreeBusy = false;
        if (on) _noStepFreeRoute = true;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(on
              ? 'No step-free route to ${widget.destination.name}: it can only be '
                  'reached by stairs. Showing the route with stairs.'
              : e.message),
        ));
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
    _startLive(route);
  }

  /// Every point of the route has a GPS position (older backends did not
  /// send them for the floor plans): then it can be followed live.
  static bool _canFollow(NavigationRoute route) =>
      route.legs.isNotEmpty &&
      route.legs.every((l) =>
          !l.isIndoor || (l.points.isNotEmpty && l.points.every((p) => p.lat != null && p.lng != null)));

  /// Live guidance with every sensor (real backend routes).
  void _startLive(NavigationRoute route) {
    _stopLive();
    if (ApiService.useMock || !_canFollow(route)) return;
    // A start picked from the list or scanned from a sign is exact: its
    // floor is certain (a GPS start is not).
    final guide = LiveGuide(route: route, startFloorKnown: !_start.live);
    if (!guide.geometry.usable) {
      guide.dispose();
      return;
    }
    guide.addListener(_onGuide);
    _guide = guide;
    final frames = _frames ??= createTicker((_) => _guide?.frame());
    if (!frames.isActive) frames.start();
    guide.start();
  }

  void _stopLive() {
    if (_frames?.isActive ?? false) _frames!.stop();
    final g = _guide;
    _guide = null;
    if (g != null) {
      g.removeListener(_onGuide);
      g.dispose(); // stops GPS and sensors
    }
  }

  /// Something live guidance shows has changed (step, metres, floor card ...).
  void _onGuide() {
    final g = _guide;
    if (g == null || !mounted) return;
    final notice = g.takeNotice();
    if (notice != null) {
      HapticFeedback.heavyImpact();
      _toast(notice);
    }
    final from = g.rerouteRequest;
    if (from != null) {
      _rerouteFrom(from.latitude, from.longitude, accuracy: from.accuracy);
    }
    if (g.arrived && !_arrived) {
      HapticFeedback.heavyImpact();
      unawaited(SpotLocator.rememberSpot(widget.destination.id));
      setState(() => _arrived = true);
      // Not inside the guide's own notification: stop it right after.
      Future.microtask(_stopLive);
      return;
    }
    final k = g.stepIndex;
    if (k > _stepIndex) HapticFeedback.mediumImpact();
    setState(() {
      _stepIndex = k;
      _floorPrompt = null;
    });
  }

  void _next(NavigationRoute route) {
    final g = _guide;
    if (g != null) {
      // Live: Next jumps ahead (the sensors carry on from there).
      if (g.wait != null) {
        HapticFeedback.selectionClick();
        g.confirmFloor();
      } else if (_stepIndex >= route.steps.length - 1) {
        HapticFeedback.mediumImpact();
        g.markArrived();
      } else {
        HapticFeedback.selectionClick();
        g.jumpToStep(_stepIndex + 1);
      }
      return;
    }
    // Confirming the stairs/lift card moves on to the new floor.
    if (_floorPrompt != null) {
      HapticFeedback.selectionClick();
      setState(() {
        _floorPrompt = null;
        _stepIndex++;
      });
      return;
    }
    // About to arrive on another floor: show the floor card first.
    final prompt = _promptFor(route, _stepIndex);
    if (prompt != null && _fullScreen) {
      HapticFeedback.heavyImpact();
      setState(() => _floorPrompt = prompt);
      return;
    }
    if (_stepIndex >= route.steps.length - 1) {
      HapticFeedback.mediumImpact();
      setState(() => _arrived = true);
    } else {
      HapticFeedback.selectionClick();
      setState(() => _stepIndex++);
    }
  }

  /// The floor card for going from step [i] to step [i] + 1, or null when
  /// both are on the same floor.
  _FloorPrompt? _promptFor(NavigationRoute route, int i) {
    if (i + 1 >= route.steps.length) return null;
    final here = route.steps[i];
    final next = route.steps[i + 1];
    final from = here.floor;
    final to = next.floor;
    if (from == null || to == null || from == to) return null;
    final via = here.isFloorChange ? here.type : (route.connectorType ?? 'stairs');
    return _FloorPrompt(from: from, to: to, via: via);
  }

  void _previous() {
    final g = _guide;
    if (g != null) {
      if (_stepIndex > 1) {
        HapticFeedback.selectionClick();
        g.jumpToStep(_stepIndex - 1);
      }
      return;
    }
    if (_floorPrompt != null) {
      setState(() => _floorPrompt = null);
      return;
    }
    if (_stepIndex > 1) {
      HapticFeedback.selectionClick();
      setState(() => _stepIndex--);
    }
  }

  void _endGuidance() {
    _stopLive();
    setState(() {
      _floorPrompt = null;
      _guiding = false;
      _stepIndex = 0;
    });
  }

  // ---------------------------------------------------------- live helpers

  /// A new route from a position (off the path outside, or on another floor
  /// inside with [floor]).
  Future<void> _rerouteFrom(double lat, double lng, {double accuracy = 10, int? floor}) async {
    final g = _guide;
    final last = _lastReroute;
    if (g == null) return;
    if (_rerouting ||
        (last != null && DateTime.now().difference(last) < const Duration(seconds: 15))) {
      if (!_rerouting) g.rerouteHandled();
      return;
    }
    setState(() {
      _rerouting = true;
      _lastReroute = DateTime.now();
    });
    try {
      final route = await _api.getRoute(
        start: _start.id,
        destination: widget.destination.id,
        stepFree: _stepFree,
        startName: 'Your location',
        startLat: lat,
        startLng: lng,
        startFloor: floor,
      );
      if (!mounted || !_guiding || _guide != g) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _route = route;
        _stepIndex = math.min(1, route.steps.length - 1);
        _floorPrompt = null;
      });
      if (_canFollow(route)) {
        g.replaceRoute(route, sigma: accuracy.clamp(3.0, 15.0).toDouble());
      } else {
        _stopLive();
      }
      _toast('New route from where you are');
    } on ApiException catch (e) {
      g.rerouteHandled();
      if (mounted) {
        _toast(e.kind == ApiErrorKind.offCampus
            ? 'You are off the campus paths. Head back towards the route.'
            : 'Could not find a new route: ${e.message}');
      }
    } finally {
      if (mounted) setState(() => _rerouting = false);
    }
  }

  /// Scan the QR code on a sign to jump to that point of the route (or get
  /// a new route from there if it is not on this one).
  Future<void> _scanSign() async {
    final route = _route;
    if (route == null) return;
    final before = AppState.startPoint.value;
    await openScanner(context, onManual: () {});
    if (!mounted || !_guiding) return;
    final here = AppState.startPoint.value;
    if (identical(here, before)) return; // nothing scanned

    var idx = -1;
    for (var i = 1; i < route.steps.length; i++) {
      if (route.steps[i].nodeId == here.id) {
        idx = i;
        break;
      }
    }
    if (idx >= 1) {
      HapticFeedback.mediumImpact();
      _guide?.jumpToStep(idx, fromSign: true);
      setState(() {
        _floorPrompt = null;
        _stepIndex = idx;
      });
      return;
    }
    try {
      final fresh = await _api.getRoute(
        start: here.id,
        destination: widget.destination.id,
        stepFree: _stepFree,
        startName: here.name,
      );
      if (!mounted || !_guiding) return;
      setState(() {
        _route = fresh;
        _start = here;
        _floorPrompt = null;
        _stepIndex = math.min(1, fresh.steps.length - 1);
      });
      final g = _guide;
      if (g != null && _canFollow(fresh)) {
        g.replaceRoute(fresh, sigma: 1.5);
      } else {
        _startLive(fresh);
      }
      _toast('New route from ${here.name}');
    } on ApiException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)));
  }

  void _openSensors() {
    final g = _guide;
    if (g == null) return;
    showSensorSheet(context, guide: g);
  }

  /// The round button next to Next: sensors, scan a sign, or pause.
  Future<void> _guideMenu(LiveGuide g) async {
    HapticFeedback.selectionClick();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final text = Theme.of(context).textTheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Auto-follow is on: the arrow and the metres move by themselves as you walk.',
                    style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('Sensors and status'),
                  onTap: () => Navigator.of(context).pop('sensors'),
                ),
                ListTile(
                  leading: const Icon(Icons.qr_code_scanner),
                  title: const Text('Scan a sign to jump there'),
                  onTap: () => Navigator.of(context).pop('scan'),
                ),
                ListTile(
                  leading: const Icon(Icons.pause_circle_outline),
                  title: const Text('Pause auto-follow'),
                  subtitle: const Text('Then you move on with Next'),
                  onTap: () => Navigator.of(context).pop('pause'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    switch (choice) {
      case 'sensors':
        _openSensors();
      case 'scan':
        unawaited(_scanSign());
      case 'pause':
        g.setPaused(true);
        _toast('Auto-follow paused. Tap the round button to follow you again.');
    }
  }

  /// The status line above the buttons and the round button next to Next:
  /// what is following you now, and what tapping the button does.
  ({IconData icon, String status, String tip, Color color, VoidCallback onTap}) _gpsLook() {
    final g = _guide;
    if (_rerouting) {
      return (
        icon: Icons.alt_route,
        status: 'Finding a new route from where you are…',
        tip: 'Rerouting',
        color: AppColors.sportsInk,
        onTap: () {},
      );
    }
    if (g == null) {
      return (
        icon: Icons.qr_code_scanner,
        status: 'Tap Next as you go, or scan a sign to jump there',
        tip: 'Scan a sign',
        color: AppColors.inkMuted,
        onTap: _scanSign,
      );
    }
    final acc = g.lastFix?.accuracy;
    final pm = acc == null ? '' : ' · ±${acc.round()} m';
    final pose = g.pose.value;
    final inside = pose?.indoor ?? false;
    final floor = pose == null ? '' : ' · ${floorLabel(pose.floor).toLowerCase()}';
    final problem = g.gpsProblem;
    // Pausing makes you tap Next for every step, so it is never one tap
    // away: the button opens a small menu (pause is one of its choices).
    void pause() => _guideMenu(g);

    if (problem != null && !inside && g.mode != GuideMode.paused && g.mode != GuideMode.simulated) {
      return (
        icon: Icons.location_disabled,
        status: problem.problem == LocateProblem.serviceOff
            ? 'Location is off: following your steps only. Tap to turn it on'
            : 'No location access: following your steps only',
        tip: 'Turn on location',
        color: AppColors.danger,
        onTap: () async {
          if (problem.problem == LocateProblem.serviceOff) {
            await LocationService.openLocationSettings();
          } else if (problem.problem == LocateProblem.deniedForever) {
            await LocationService.openAppSettings();
          }
          await g.retryGps();
        },
      );
    }
    return switch (g.mode) {
      GuideMode.gps => (
          icon: Icons.gps_fixed,
          status: 'Following you by GPS and your steps$pm',
          tip: 'Guidance options',
          color: AppColors.success,
          onTap: pause,
        ),
      GuideMode.steps => (
          icon: Icons.directions_walk,
          status: inside
              ? 'Inside: following your steps and turns$floor'
              : 'GPS is weak here: following your steps$pm',
          tip: 'Guidance options',
          color: AppColors.success,
          onTap: pause,
        ),
      GuideMode.floorChange => (
          icon: Icons.stairs_outlined,
          status: switch (g.floorSensing) {
            'barometer' => 'The floor is detected by the barometer as you go',
            'steps' => 'Your steps on the stairs are counted: it moves on by itself at the top',
            'motion' => 'The lift is felt starting and stopping: it moves on by itself',
            _ => 'Tap the button once you are on the new floor',
          },
          tip: 'Guidance options',
          color: AppColors.success,
          onTap: pause,
        ),
      GuideMode.manual => (
          icon: Icons.qr_code_scanner,
          status: 'This phone has no step sensor: tap Next as you go, or scan a sign',
          tip: 'Scan a sign',
          color: AppColors.inkMuted,
          onTap: _scanSign,
        ),
      GuideMode.paused => (
          icon: Icons.gps_off,
          status: 'Auto-follow is off: tap Next as you go',
          tip: 'Follow me again',
          color: AppColors.inkMuted,
          onTap: () => g.setPaused(false),
        ),
      GuideMode.simulated => (
          icon: Icons.smart_toy_outlined,
          status: 'Simulating the walk for testing. Tap to stop',
          tip: 'Stop the simulation',
          color: AppColors.sportsInk,
          onTap: () => g.setSimulating(false),
        ),
      GuideMode.starting => (
          icon: Icons.gps_not_fixed,
          status: 'Starting GPS and sensors…',
          tip: 'Guidance options',
          color: AppColors.sportsInk,
          onTap: pause,
        ),
    };
  }

  double _remainingMeters(NavigationRoute route) {
    final g = _guide;
    if (g != null) return g.remaining;
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
      final startProblem = _errorKind == ApiErrorKind.noRoute ||
          _errorKind == ApiErrorKind.offCampus ||
          _errorKind == ApiErrorKind.notFound;
      return ErrorView(
        message: _error ?? 'No route found.',
        kind: _errorKind,
        onRetry: _retry,
        // A wrong or unreachable start is fixed by choosing another one.
        actionLabel: startProblem ? 'Choose another start' : null,
        actionIcon: Icons.my_location,
        onAction: startProblem ? _changeStart : null,
      );
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
      _FromRow(name: _start.name, onChange: _changeStart),
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
      // Only when it can matter: the route changes floors, or it is on.
      if (d.floor > 0 || route.connectorType != null || _stepFree) ...[
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
                      _noStepFreeRoute
                          ? 'Not available here: stairs only'
                          : _stepFree
                              ? 'On for this route: lifts and ramps only'
                              : 'Off: turn on to avoid stairs',
                      style: text.bodySmall?.copyWith(
                        color: _noStepFreeRoute ? AppColors.danger : AppColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (_stepFreeBusy)
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                )
              else
                Switch(
                  value: _stepFree,
                  // Greyed out once we know this place has no step-free way in.
                  onChanged: _noStepFreeRoute ? null : _setStepFree,
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

  /// Map tab for a route from the real backend: the outdoor line on the map,
  /// then one floor plan per indoor leg. Each card opens full screen.
  List<Widget> _liveMapContent(NavigationRoute route, TextTheme text) {
    final parts = RouteMapPart.of(route);

    Widget header(String title, int part) => Row(
          children: [
            Expanded(child: Text(title, style: text.titleMedium)),
            TextButton.icon(
              onPressed: () => _openRouteMap(route, part),
              icon: const Icon(Icons.open_in_full, size: 18),
              label: const Text('Full screen'),
              style: TextButton.styleFrom(foregroundColor: lineInk(_line)),
            ),
          ],
        );

    return [
      for (var i = 0; i < parts.length; i++) ...[
        header(
          parts[i].isOutdoor
              ? 'Outside'
              : 'Inside, ${floorLabel(parts[i].leg!.floor).toLowerCase()}',
          i,
        ),
        const SizedBox(height: 6),
        if (parts[i].isOutdoor)
          LiveCampusMap(route: route.outdoorPolyline, color: _line, height: 340)
        else
          _floorCard(parts[i].leg!),
        const SizedBox(height: 22),
      ],
      if (parts.isEmpty)
        AppCard(
          child: Text('There is no map for this route yet. Follow the steps.', style: text.bodyMedium),
        ),
    ];
  }

  /// A tall card with one floor's part of the route, opened zoomed onto it.
  Widget _floorCard(RouteLeg leg) {
    return Container(
      height: 360,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.mist),
      ),
      clipBehavior: Clip.antiAlias,
      child: FloorPlanViewer(
        image: leg.image!,
        imageWidth: leg.imageWidth,
        imageHeight: leg.imageHeight,
        route: leg.points,
        color: _line,
        focus: routeFocus(leg.points, leg.imageWidth, leg.imageHeight),
        controls: false,
      ),
    );
  }

  void _openRouteMap(NavigationRoute route, int part) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RouteMapScreen(
        route: route,
        title: widget.destination.name,
        color: _line,
        initialPart: part,
      ),
    ));
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
    final g = _guide;
    final wait = g?.wait;
    // Live: the stairs / lift card comes from where you are (and closes by
    // itself when the barometer sees you reach the floor).
    final prompt = g == null
        ? _floorPrompt
        : wait == null
            ? null
            : _FloorPrompt(from: wait.from, to: wait.to, via: wait.via);
    final mismatch = g?.floorMismatch;
    final turn = g?.turnToRoute;

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
                    metresLeft: g?.metresToNext,
                  ),
                ),
              ),
              // The barometer says you went up/down somewhere else.
              if (mismatch != null && prompt == null)
                Positioned(
                  top: top + 128,
                  left: 12,
                  right: 12,
                  child: _WrongFloorBanner(
                    floor: mismatch,
                    routeFloor: g?.pose.value?.floor ?? (step.floor ?? 0),
                    onReroute: () {
                      final pose = g?.pose.value;
                      if (pose == null) return;
                      _rerouteFrom(pose.geo.lat, pose.geo.lng, floor: mismatch);
                    },
                    onDismiss: () => g?.dismissMismatch(),
                  ),
                ),
              // Standing still facing away from the route: which way to turn.
              if (turn != null && turn.abs() >= 60 && prompt == null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 18,
                  child: Center(child: _TurnHint(angle: turn)),
                ),
              // The stairs / lift moment covers the map until confirmed.
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  child: prompt == null
                      ? const SizedBox.shrink()
                      : _FloorChangeCard(
                          key: ValueKey('${prompt.from}-${prompt.to}'),
                          prompt: prompt,
                          color: _line,
                          progress: wait?.progress,
                          automatic: wait?.automatic ?? false,
                          sensing: g?.floorSensing,
                          onScan: _scanSign,
                          onConfirm: () => _next(route),
                          onBack: _previous,
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

  /// The outdoor map while you are outside, the floor plan of your floor
  /// once you are inside. Live, the person icon follows you every frame;
  /// otherwise it sits at the start of the current step.
  Widget _guidanceMap(NavigationRoute route, RouteStep step) {
    final g = _guide;
    final pose = g?.pose.value;
    final inside = pose?.indoor ?? step.space == 'indoor';
    final floor = pose?.floor ?? step.floor ?? 0;

    Widget child = const SizedBox.shrink();
    var key = 'outside';

    if (!inside) {
      final lat = step.lat, lng = step.lng;
      child = LiveCampusMap(
        route: route.outdoorPolyline,
        color: _line,
        person: g == null && lat != null && lng != null ? GeoPoint(lat, lng) : null,
        live: g?.pose,
        follow: true,
        // The way you are walking points up, like Google Maps navigation.
        headingUp: true,
        fill: true,
      );
    } else {
      RouteLeg? found;
      for (final l in route.indoorLegs) {
        if (l.floor == floor) {
          found = l;
          break;
        }
      }
      // final, so the null check below still holds inside the builders.
      final leg = found;
      final px = step.x, py = step.y;
      if (leg != null && (g != null || (px != null && py != null))) {
        key = 'inside-${leg.floor}';
        child = Stack(
          children: [
            // Pinch, double-tap or the buttons to zoom; opens on this floor's
            // part of the route. Lines and the person icon keep their size.
            Positioned.fill(
              child: FloorPlanViewer(
                image: leg.image!,
                imageWidth: leg.imageWidth,
                imageHeight: leg.imageHeight,
                route: leg.points,
                color: _line,
                person: g == null && px != null && py != null ? MapPoint(px, py) : null,
                live: g?.pose,
                focus: routeFocus(leg.points, leg.imageWidth, leg.imageHeight),
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
    final gps = _gpsLook();
    final remaining = _remainingMeters(route);
    final g = _guide;
    final total = g == null ? 0.0 : g.geometry.length * g.geometry.scale;
    final progress = g != null && total > 0
        ? (1 - remaining / total).clamp(0.0, 1.0).toDouble()
        : _stepIndex / (route.steps.length - 1);
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
          const SizedBox(height: 12),
          // What guidance is doing: following you by GPS, waiting for a fix,
          // or (inside) waiting for you to tap Next / scan a sign.
          if (!ApiService.useMock)
            Semantics(
              // Not a live region: the ± metres change with every GPS fix.
              button: _guide != null,
              hint: _guide != null ? 'Shows the sensors' : null,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _guide == null ? null : _openSensors,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: gps.color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          gps.status,
                          maxLines: 2,
                          style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                        ),
                      ),
                      if (_guide != null)
                        const Icon(Icons.tune, size: 18, color: AppColors.inkMuted),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (_stepIndex > 1) ...[
                OutlinedButton(
                  onPressed: _previous,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(56, 56),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Icon(Icons.arrow_back, semanticLabel: 'Previous step'),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _line,
                    foregroundColor: readableOnLine(_line),
                    minimumSize: const Size(0, 56),
                  ),
                  onPressed: () => _next(route),
                  child: Text(atEnd ? "I've arrived" : 'Next step'),
                ),
              ),
              if (!ApiService.useMock) ...[
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  tooltip: gps.tip,
                  style: IconButton.styleFrom(minimumSize: const Size(56, 56)),
                  onPressed: gps.onTap,
                  icon: Icon(gps.icon, color: gps.color),
                ),
              ],
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
      const SizedBox(height: 24),
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
    this.metresLeft,
  });

  /// Live GPS: metres to the end of this step (counts down as you walk).
  final double? metresLeft;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final onColor = readableOnLine(line);
    final metres = metresLeft ?? step.distance ?? 0;

    // Each new instruction is read out by screen readers.
    return Semantics(
      liveRegion: true,
      child: Container(
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
      child: SingleChildScrollView(
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

/// Going from one floor to another during guidance.
class _FloorPrompt {
  final int from;
  final int to;
  final String via; // "stairs" or "lift"

  const _FloorPrompt({required this.from, required this.to, required this.via});

  bool get up => to > from;
}

String _floorShort(int f) => f == 0 ? 'G' : '$f';

/// Full card for the stairs / lift moment: big icon, which way, which floor,
/// and a button to say you have arrived on it.
class _FloorChangeCard extends StatelessWidget {
  final _FloorPrompt prompt;
  final Color color;
  final VoidCallback onConfirm;
  final VoidCallback onBack;

  /// Live guidance with a barometer: how much of the climb is done (0..1),
  /// null before it starts.
  final double? progress;

  /// The card will close by itself on the new floor.
  final bool automatic;

  /// What notices the new floor: "barometer", "steps" or "motion".
  final String? sensing;

  /// Scan the QR sign at the landing (exact on any phone).
  final VoidCallback? onScan;

  const _FloorChangeCard({
    super.key,
    required this.prompt,
    required this.color,
    required this.onConfirm,
    required this.onBack,
    this.progress,
    this.automatic = false,
    this.sensing,
    this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final on = readableOnLine(color);
    final lift = prompt.via == 'lift';
    // "to floor 1" / "to the ground floor"
    final target = prompt.to == 0 ? 'the ground floor' : 'floor ${prompt.to}';
    final verb = lift ? 'Take the lift' : 'Take the stairs';
    final way = prompt.up ? 'up' : 'down';
    final still = MediaQuery.of(context).disableAnimations;

    final sensingText = switch (sensing) {
      'steps' => 'Your steps on the stairs are counted: guidance goes on by itself '
          'when the bar is full, on $target.',
      'motion' => 'The lift is felt starting and stopping: guidance goes on by itself '
          'when it stops at $target, or as you walk out.',
      _ => 'The barometer notices when you reach $target: guidance goes on by itself.',
    };

    return Semantics(
      liveRegion: true,
      label: '$verb $way to $target',
      child: Container(
        color: color,
        child: SafeArea(
          bottom: false,
          // Fits any screen: compact on short ones, and scrolls rather than
          // overflowing if it still does not fit (large text settings).
          child: LayoutBuilder(
            builder: (context, box) {
              final compact = box.maxHeight < 620;
              final tiny = box.maxHeight < 470;
              final pad = compact ? 16.0 : 24.0;
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(24, pad, 24, pad),
                      child: Column(
                        children: [
                          const Spacer(),
                          if (!tiny)
                            Icon(lift ? Icons.elevator_outlined : Icons.stairs_outlined,
                                size: compact ? 56 : 84, color: on),
                          if (!tiny) const SizedBox(height: 4),
                          // A gentle bob in the direction to go (still if reduce motion is on).
                          TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: 1),
                            duration: Duration(milliseconds: still ? 0 : 900),
                            curve: Curves.easeOutBack,
                            builder: (context, t, child) => Transform.translate(
                              offset: Offset(0, (prompt.up ? -1 : 1) * 8 * t),
                              child: child,
                            ),
                            child: Icon(
                              prompt.up ? Icons.keyboard_double_arrow_up : Icons.keyboard_double_arrow_down,
                              size: compact ? 32 : 44,
                              color: on.withValues(alpha: 0.85),
                            ),
                          ),
                          SizedBox(height: compact ? 8 : 16),
                          Text(
                            '$verb $way',
                            textAlign: TextAlign.center,
                            style: (compact ? text.titleLarge : text.headlineSmall)
                                ?.copyWith(color: on, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'to $target',
                            textAlign: TextAlign.center,
                            style: (compact ? text.titleMedium : text.titleLarge)
                                ?.copyWith(color: on.withValues(alpha: 0.9), fontWeight: FontWeight.w500),
                          ),
                          SizedBox(height: compact ? 12 : 20),
                          // G -> 1 badge
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _FloorBadge(label: _floorShort(prompt.from), color: color, faded: true, small: compact),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: Icon(Icons.arrow_forward, color: on),
                              ),
                              _FloorBadge(label: _floorShort(prompt.to), color: color, small: compact),
                            ],
                          ),
                          if (automatic) ...[
                            SizedBox(height: compact ? 14 : 22),
                            SizedBox(
                              width: 220,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 6,
                                  color: on,
                                  backgroundColor: on.withValues(alpha: 0.25),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              progress == null
                                  ? (lift ? 'Waiting for the lift to move…' : 'Counting your steps on the stairs…')
                                  : (lift ? 'In the lift: ${(progress! * 100).round()} %' : 'On the stairs: ${(progress! * 100).round()} %'),
                              textAlign: TextAlign.center,
                              style: text.bodyMedium?.copyWith(color: on.withValues(alpha: 0.95)),
                            ),
                            if (!compact) ...[
                              const SizedBox(height: 4),
                              Text(
                                sensingText,
                                textAlign: TextAlign.center,
                                style: text.bodySmall?.copyWith(color: on.withValues(alpha: 0.8)),
                              ),
                            ],
                          ],
                          const Spacer(),
                          SizedBox(height: compact ? 12 : 20),
                          // Automatic: the tap is only a backup, so a lighter button.
                          SizedBox(
                            width: double.infinity,
                            height: compact ? 48 : 54,
                            child: automatic
                                ? OutlinedButton.icon(
                                    onPressed: onConfirm,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: on,
                                      side: BorderSide(color: on.withValues(alpha: 0.7), width: 1.5),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    ),
                                    icon: const Icon(Icons.check),
                                    label: Text('Already on $target? Tap', overflow: TextOverflow.ellipsis),
                                  )
                                : FilledButton.icon(
                                    onPressed: onConfirm,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: on,
                                      foregroundColor: color,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    ),
                                    icon: const Icon(Icons.check),
                                    label: Text("I'm on $target", overflow: TextOverflow.ellipsis),
                                  ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 4,
                            children: [
                              if (onScan != null)
                                TextButton.icon(
                                  onPressed: onScan,
                                  style: TextButton.styleFrom(foregroundColor: on, minimumSize: const Size(48, 44)),
                                  icon: const Icon(Icons.qr_code_scanner, size: 20),
                                  label: const Text('Scan landing sign'),
                                ),
                              TextButton.icon(
                                onPressed: onBack,
                                style: TextButton.styleFrom(foregroundColor: on, minimumSize: const Size(48, 44)),
                                icon: const Icon(Icons.undo, size: 20),
                                label: const Text('Previous step'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// "You seem to be on floor 2": the barometer saw you change floor away
/// from the route's stairs / lift.
class _WrongFloorBanner extends StatelessWidget {
  final int floor;
  final int routeFloor;
  final VoidCallback onReroute;
  final VoidCallback onDismiss;

  const _WrongFloorBanner({
    required this.floor,
    required this.routeFloor,
    required this.onReroute,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    String name(int f) => f == 0 ? 'the ground floor' : 'floor $f';
    return Semantics(
      liveRegion: true,
      child: Material(
        color: const Color(0xFFFFF4E5),
        elevation: 4,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.layers_outlined, color: Color(0xFF8A5300)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'You seem to be on ${name(floor)}. The route goes on ${name(routeFloor)}.',
                      style: text.bodyMedium?.copyWith(color: AppColors.ink, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: onDismiss,
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF8A5300)),
                    child: Text("I'm on ${name(routeFloor)}"),
                  ),
                  TextButton(
                    onPressed: onReroute,
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF8A5300)),
                    child: const Text('New route from here'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Standing still and facing away from the route: "Turn around".
class _TurnHint extends StatelessWidget {
  final double angle; // -180..180, positive = turn right

  const _TurnHint({required this.angle});

  @override
  Widget build(BuildContext context) {
    final around = angle.abs() >= 135;
    final label = around ? 'Turn around' : (angle > 0 ? 'Turn right' : 'Turn left');
    final icon = around ? Icons.u_turn_left : (angle > 0 ? Icons.turn_right : Icons.turn_left);
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.ink.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              '$label to face the route',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

class _FloorBadge extends StatelessWidget {
  final String label;
  final Color color;
  final bool faded;
  final bool small;

  const _FloorBadge({required this.label, required this.color, this.faded = false, this.small = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: small ? 46 : 56,
      height: small ? 46 : 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: faded ? Colors.white.withValues(alpha: 0.25) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: small ? 20 : 24,
          fontWeight: FontWeight.w700,
          color: faded ? Colors.white : color,
        ),
      ),
    );
  }
}

/// "From Main Gate   Change" at the top of the route: where the route
/// starts, changeable in one tap.
class _FromRow extends StatelessWidget {
  final String name;
  final VoidCallback onChange;

  const _FromRow({required this.name, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Starting from $name. Change start point',
      excludeSemantics: true,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.mist),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onChange,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.trip_origin, size: 20, color: AppColors.ink),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: 'From  ',
                          style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
                        ),
                        TextSpan(text: name, style: text.titleSmall),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    'Change',
                    style: text.labelLarge?.copyWith(color: AppColors.academic),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
