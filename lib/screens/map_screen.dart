import 'package:flutter/material.dart';
import '../data/mock_campus.dart';
import '../models/destination.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import '../widgets/campus_map.dart';
import '../widgets/destination_card.dart';
import '../widgets/floor_plan.dart';
import '../widgets/floor_selector.dart';
import '../widgets/map_frame.dart';
import '../widgets/pill.dart';
import '../widgets/segment_toggle.dart';
import '../widgets/slide_route.dart';
import '../widgets/state_views.dart';
import 'navigation_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  int _mode = 0; // 0 = outdoors, 1 = indoors
  String _building = 'Academic Building';
  int _floor = 0;

  void _openDestination(Destination destination) {
    Navigator.of(context).push(slideRoute(NavigationScreen(destination: destination)));
  }

  /// Tapping a building on the outdoor map lists what is inside it.
  void _showBuilding(CampusBuilding building) {
    final items =
        MockCampus.destinations.where((d) => d.building == building.name).toList();
    final text = Theme.of(context).textTheme;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(building.name, style: text.headlineSmall),
              const SizedBox(height: 4),
              Text(
                items.isEmpty
                    ? 'No destinations added here yet.'
                    : '${items.length} ${items.length == 1 ? 'destination' : 'destinations'}',
                style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
              ),
              const SizedBox(height: 16),
              for (final d in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DestinationCard(
                    destination: d,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _openDestination(d);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
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
          Expanded(child: _mode == 0 ? _outdoors(text) : _indoors(text)),
        ],
      ),
    );
  }

  Widget _outdoors(TextTheme text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MapFrame(
            aspectRatio: MockCampus.canvasWidth / MockCampus.canvasHeight,
            zoomable: true,
            child: CampusMap(onBuildingTap: _showBuilding),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final b in MockCampus.buildings)
                Pill(text: b.name, color: lineColorForBuilding(b.name)),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Tap a building to see what is inside. Pinch to zoom.',
            style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }

  Widget _indoors(TextTheme text) {
    final building = MockCampus.buildingNamed(_building);
    final plan = MockCampus.floorPlans[_building];
    final line = lineColorForBuilding(_building);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: MockCampus.buildings.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final b = MockCampus.buildings[i];
              final selected = b.name == _building;
              final c = lineColorForBuilding(b.name);
              return Material(
                color: selected ? c : Colors.white,
                shape: StadiumBorder(side: BorderSide(color: selected ? c : AppColors.mist)),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => setState(() {
                    _building = b.name;
                    _floor = 0;
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      child: Text(
                        b.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: selected ? readableOnLine(c) : AppColors.ink,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        if (plan == null || building == null)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: EmptyView(
              icon: Icons.layers_outlined,
              title: 'Floor plan coming soon',
              message: 'The $_building is being mapped. The Academic Building is the pilot.',
            ),
          )
        else ...[
          FloorSelector(
            floors: [for (var f = 0; f <= building.topFloor; f++) f],
            selected: _floor,
            color: line,
            onChanged: (f) => setState(() => _floor = f),
          ),
          const SizedBox(height: 16),
          MapFrame(
            aspectRatio: MockCampus.indoorWidth / MockCampus.indoorHeight,
            zoomable: true,
            child: FloorPlan(
              rooms: plan[_floor] ?? const [],
              floor: _floor,
              color: line,
              tappableRoomIds: {
                for (final d in MockCampus.destinations)
                  if (d.building == _building) d.id,
              },
              onRoomTap: (room) {
                for (final d in MockCampus.destinations) {
                  if (d.id == room.id) _openDestination(d);
                }
              },
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Coloured rooms have directions. Tap one to start.',
            style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ],
    );
  }
}
