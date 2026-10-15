import 'package:flutter/material.dart';

import '../models/destination.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../widgets/live_floor_plan.dart';
import '../widgets/live_route_map.dart';
import '../widgets/map_frame.dart';
import '../widgets/segment_toggle.dart';
import '../widgets/slide_route.dart';
import '../widgets/state_views.dart';
import 'navigation_screen.dart';

/// The "Map" tab when the app talks to the real backend: the OpenStreetMap
/// campus with a pin per place, and the floor plan with a dot per indoor place.
/// (In demo mode the schematic [MapScreen] is used instead.)
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  // Ground floor of Block A / main building. Matches GET /api/floors.
  // When more floors exist, fetch /api/floors instead of hard-coding this.
  static const _image = 'ground.png';
  static const _imageWidth = 1357.0;
  static const _imageHeight = 882.0;

  final _api = const ApiService();
  List<Destination> _all = const [];
  bool _loading = true;
  String? _error;
  int _mode = 0; // 0 = outdoors, 1 = indoors

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final result = await _api.searchDestinations();
      if (!mounted) return;
      setState(() {
        _all = result;
        _loading = false;
        _error = null;
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

  void _open(Destination d) {
    Navigator.of(context).push(slideRoute(NavigationScreen(destination: d)));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text('Campus map', style: text.headlineSmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
            child: SegmentToggle(
              labels: const ['Outdoors', 'Indoors'],
              selected: _mode,
              onChanged: (i) => setState(() => _mode = i),
            ),
          ),
          Expanded(child: _body(text)),
        ],
      ),
    );
  }

  Widget _body(TextTheme text) {
    if (_loading) return const LoadingList();
    if (_error != null) return ErrorView(message: _error!, onRetry: _retry);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: _mode == 0 ? _outdoors(text) : _indoors(text),
    );
  }

  List<Widget> _outdoors(TextTheme text) {
    return [
      LiveCampusMap(pins: _all, onPinTap: _open, height: 420),
      const SizedBox(height: 14),
      Text(
        'Tap a pin to get directions. Pinch to zoom.',
        style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
      ),
    ];
  }

  List<Widget> _indoors(TextTheme text) {
    final rooms = [for (final d in _all) if (d.isIndoor) d];

    return [
      Text('Ground floor', style: text.titleMedium),
      const SizedBox(height: 12),
      MapFrame(
        aspectRatio: _imageWidth / _imageHeight,
        zoomable: true,
        child: LiveFloorPlan(
          image: _image,
          imageWidth: _imageWidth,
          imageHeight: _imageHeight,
          pins: [
            for (final d in rooms)
              FloorPin(label: d.name, x: d.x!, y: d.y!, onTap: () => _open(d)),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Text(
        'Dots are places with directions. Tap one to start.',
        style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
      ),
    ];
  }
}
