import 'package:flutter/material.dart';

import '../models/destination.dart';
import '../models/floor_info.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import '../widgets/app_card.dart';
import '../widgets/floor_selector.dart';
import '../widgets/live_floor_plan.dart';
import '../widgets/live_route_map.dart';
import '../widgets/map_frame.dart';
import '../widgets/segment_toggle.dart';
import '../widgets/slide_route.dart';
import '../widgets/state_views.dart';
import 'navigation_screen.dart';

/// The "Map" tab when the app talks to the real backend: the OpenStreetMap
/// campus with a pin per outdoor place, and every floor plan of the main
/// building with a dot per indoor place on that floor.
/// (In demo mode the schematic [MapScreen] is used instead.)
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  final _api = const ApiService();
  List<Destination> _all = const [];
  List<FloorInfo> _floors = FloorInfo.fallback;
  bool _loading = true;
  String? _error;
  int _mode = 0; // 0 = outdoors, 1 = indoors
  int _floor = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch({bool refresh = false}) async {
    try {
      final catalog = await _api.loadCatalog(refresh: refresh);
      if (!mounted) return;
      setState(() {
        _all = catalog.places;
        _floors = catalog.floors;
        if (!_floors.any((f) => f.floor == _floor)) _floor = _floors.first.floor;
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
    _fetch(refresh: true);
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

    return RefreshIndicator(
      onRefresh: () => _fetch(refresh: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: _mode == 0 ? _outdoors(text) : _indoors(text),
      ),
    );
  }

  List<Widget> _outdoors(TextTheme text) {
    // Indoor rooms have a GPS point too now; showing them here would stack a
    // hundred pins on the building. They live on the Indoors tab.
    final outside = [for (final d in _all) if (!d.isIndoor && d.hasGeo) d];
    return [
      LiveCampusMap(pins: outside, onPinTap: _open, height: 420),
      const SizedBox(height: 14),
      Text(
        'Tap a pin to get directions. Pinch to zoom.',
        style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
      ),
    ];
  }

  List<Widget> _indoors(TextTheme text) {
    final floor = _floors.firstWhere(
      (f) => f.floor == _floor,
      orElse: () => _floors.first,
    );
    final rooms = [
      for (final d in _all)
        if (d.isIndoor && d.floor == floor.floor) d,
    ];

    return [
      FloorSelector(
        floors: [for (final f in _floors) f.floor],
        selected: floor.floor,
        onChanged: (f) => setState(() => _floor = f),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(child: Text(floor.label, style: text.titleMedium)),
          Text(
            '${rooms.length} places',
            style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
      const SizedBox(height: 12),
      MapFrame(
        // A new floor starts zoomed out again.
        key: ValueKey('floor-${floor.floor}'),
        aspectRatio: floor.imageWidth / floor.imageHeight,
        zoomable: true,
        builder: (context, zoom) => LiveFloorPlan(
          image: floor.image,
          imageWidth: floor.imageWidth,
          imageHeight: floor.imageHeight,
          zoom: zoom,
          pins: [
            for (final d in rooms)
              FloorPin(label: d.name, x: d.x!, y: d.y!, onTap: () => _open(d)),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Text(
        'Tap a dot for directions. Pinch or double-tap to zoom; names show up close.',
        style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
      ),
      if (rooms.isNotEmpty) ...[
        const SizedBox(height: 22),
        Text('On this floor', style: text.titleMedium),
        const SizedBox(height: 10),
        for (final d in rooms) ...[
          _RoomRow(destination: d, onTap: () => _open(d)),
          const SizedBox(height: 8),
        ],
      ],
    ];
  }
}

class _RoomRow extends StatelessWidget {
  final Destination destination;
  final VoidCallback onTap;

  const _RoomRow({required this.destination, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = destination;
    final inside = d.withinName;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(iconForType(d.type), size: 20, color: AppColors.academic),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.name, style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  inside == null ? d.building : 'Inside the $inside · ${d.building}',
                  style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.inkMuted),
        ],
      ),
    );
  }
}
