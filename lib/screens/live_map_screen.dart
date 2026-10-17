import 'package:flutter/material.dart';

import '../models/destination.dart';
import '../models/floor_info.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import '../widgets/floor_plan_viewer.dart';
import '../widgets/floor_selector.dart';
import '../widgets/live_floor_plan.dart';
import '../widgets/live_route_map.dart';
import '../widgets/place_card.dart';
import '../widgets/segment_toggle.dart';
import '../widgets/slide_route.dart';
import '../widgets/state_views.dart';
import 'navigation_screen.dart';

/// The "Map" tab when the app talks to the real backend.
///
/// The map takes the whole tab. Outdoors: the satellite / street map with a
/// pin per outdoor place. Indoors: a floor switch and the floor plan, with a
/// sheet you pull up to list or search the places. Tapping a pin or a list
/// row picks the place (the map flies to it) and shows a card with a
/// "Directions" button. (In demo mode the schematic [MapScreen] is used.)
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  static const _peek = 92.0; // visible height of the closed sheet
  static const _cardSpace = 168.0; // room the place card needs at the bottom

  final _api = const ApiService();
  final _sheet = DraggableScrollableController();
  final _search = TextEditingController();

  List<Destination> _all = const [];
  List<FloorInfo> _floors = FloorInfo.fallback;
  bool _loading = true;
  String? _error;
  int _mode = 1; // 0 = outdoors, 1 = indoors (most places are inside)
  int _floor = 0;
  Destination? _selected;
  String _query = '';
  GlobalKey<FloorPlanViewerState> _viewerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _sheet.dispose();
    _search.dispose();
    super.dispose();
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

  void _directions(Destination d) {
    Navigator.of(context).push(slideRoute(NavigationScreen(destination: d)));
  }

  void _setFloor(int floor) {
    if (floor == _floor) return;
    setState(() {
      _floor = floor;
      _selected = null;
      _viewerKey = GlobalKey(); // a new floor starts at its own start view
    });
  }

  void _setMode(int mode) {
    FocusScope.of(context).unfocus();
    setState(() {
      _mode = mode;
      _selected = null;
    });
  }

  /// Pick a place: switch to its floor if needed, fly the plan to it and show
  /// its card.
  void _select(Destination d) {
    FocusScope.of(context).unfocus();
    final changeFloor = d.isIndoor && d.floor != _floor;
    setState(() {
      if (changeFloor) {
        _floor = d.floor;
        _viewerKey = GlobalKey();
      }
      _selected = d;
    });
    if (d.isIndoor && d.x != null && d.y != null) {
      // After the (new) plan has laid out and set its start view.
      Future.delayed(Duration(milliseconds: changeFloor ? 120 : 30), () {
        if (!mounted || _selected?.id != d.id) return;
        _viewerKey.currentState?.showImagePoint(d.x!, d.y!);
      });
    }
  }

  void _clearSelection() => setState(() => _selected = null);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    // Back closes the place card first.
    return PopScope(
      canPop: _selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text('Campus map', style: text.headlineSmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: SegmentToggle(
                labels: const ['Outdoors', 'Indoors'],
                selected: _mode,
                onChanged: _setMode,
              ),
            ),
            if (_mode == 1 && !_loading && _error == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: FloorSelector(
                  floors: [for (final f in _floors) f.floor],
                  selected: _floor,
                  onChanged: _setFloor,
                ),
              ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const LoadingList();
    if (_error != null) return ErrorView(message: _error!, onRetry: _retry);
    return _mode == 0 ? _outdoors() : _indoors();
  }

  Widget _card() {
    final d = _selected;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.4), end: Offset.zero)
            .animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: d == null
          ? const SizedBox.shrink()
          : PlaceCard(
              key: ValueKey(d.id),
              destination: d,
              onClose: _clearSelection,
              onDirections: () => _directions(d),
            ),
    );
  }

  Widget _outdoors() {
    // Indoor rooms have a GPS point too now; showing them here would stack a
    // hundred pins on the building. They live on the Indoors tab.
    final outside = [for (final d in _all) if (!d.isIndoor && d.hasGeo) d];
    return Stack(
      children: [
        Positioned.fill(
          child: LiveCampusMap(
            pins: outside,
            onPinTap: _select,
            fill: true,
            bottomInset: _selected != null ? _cardSpace : 0,
          ),
        ),
        Positioned(left: 12, right: 12, bottom: 12, child: _card()),
      ],
    );
  }

  Widget _indoors() {
    final floor = _floors.firstWhere((f) => f.floor == _floor, orElse: () => _floors.first);
    final rooms = [for (final d in _all) if (d.isIndoor && d.floor == floor.floor) d];
    final selected = _selected;

    return LayoutBuilder(
      builder: (context, constraints) {
        final peek = (_peek / constraints.maxHeight).clamp(0.08, 0.4).toDouble();
        return Stack(
          children: [
            Positioned.fill(
              child: FloorPlanViewer(
                key: _viewerKey,
                image: floor.image,
                imageWidth: floor.imageWidth,
                imageHeight: floor.imageHeight,
                cover: true,
                bottomInset: selected != null ? _cardSpace : _peek,
                pins: [
                  for (final d in rooms)
                    FloorPin(
                      label: d.name,
                      x: d.x!,
                      y: d.y!,
                      selected: d.id == selected?.id,
                      onTap: () => _select(d),
                    ),
                ],
              ),
            ),
            if (selected == null)
              DraggableScrollableSheet(
                controller: _sheet,
                initialChildSize: peek,
                minChildSize: peek,
                maxChildSize: 0.9,
                snap: true,
                builder: (context, scroll) => _PlacesSheet(
                  scroll: scroll,
                  floor: floor,
                  rooms: rooms,
                  all: [for (final d in _all) if (d.isIndoor) d],
                  query: _query,
                  search: _search,
                  onQuery: (q) => setState(() => _query = q),
                  onSearchTap: () {
                    if (_sheet.isAttached) {
                      _sheet.animateTo(0.9,
                          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
                    }
                  },
                  onPick: _select,
                ),
              ),
            Positioned(left: 12, right: 12, bottom: 12, child: _card()),
          ],
        );
      },
    );
  }
}

/// The pull-up list under the floor plan: a search box, then the places on
/// this floor (or, while searching, matching places on every floor).
class _PlacesSheet extends StatelessWidget {
  final ScrollController scroll;
  final FloorInfo floor;
  final List<Destination> rooms;
  final List<Destination> all;
  final String query;
  final TextEditingController search;
  final ValueChanged<String> onQuery;
  final VoidCallback onSearchTap;
  final ValueChanged<Destination> onPick;

  const _PlacesSheet({
    required this.scroll,
    required this.floor,
    required this.rooms,
    required this.all,
    required this.query,
    required this.search,
    required this.onQuery,
    required this.onSearchTap,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final searching = query.trim().isNotEmpty;
    final list = searching ? [for (final d in all) if (d.matches(query)) d] : rooms;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.platform,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, -2))],
      ),
      child: ListView.builder(
        controller: scroll,
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: list.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(top: 10, bottom: 10),
                    decoration: BoxDecoration(
                      color: AppColors.inkMuted.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    height: 48,
                    child: TextField(
                      controller: search,
                      onTap: onSearchTap,
                      onChanged: onQuery,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Find a room on the map',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: searching
                            ? IconButton(
                                tooltip: 'Clear',
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  search.clear();
                                  onQuery('');
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: EdgeInsets.zero,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: AppColors.mist),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: AppColors.mist),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                  child: Text(
                    searching
                        ? '${list.length} ${list.length == 1 ? 'match' : 'matches'} on all floors'
                        : '${rooms.length} places on the ${floor.label.toLowerCase()}',
                    style: text.labelLarge?.copyWith(color: AppColors.inkMuted),
                  ),
                ),
              ],
            );
          }
          final d = list[i - 1];
          return _PlaceRow(
            destination: d,
            showFloor: searching,
            onTap: () => onPick(d),
          );
        },
      ),
    );
  }
}

class _PlaceRow extends StatelessWidget {
  final Destination destination;
  final bool showFloor;
  final VoidCallback onTap;

  const _PlaceRow({required this.destination, required this.showFloor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = destination;
    final inside = d.withinName;
    final where = showFloor
        ? d.locationLine
        : (inside == null ? d.building : 'Inside the $inside · ${d.building}');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.mist),
              ),
              child: Icon(iconForType(d.type), size: 19, color: AppColors.academic),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.name, style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    where,
                    style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.place_outlined, size: 20, color: AppColors.inkMuted),
          ],
        ),
      ),
    );
  }
}
