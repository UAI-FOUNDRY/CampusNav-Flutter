import 'package:flutter/material.dart';
import '../models/destination.dart';
import '../models/start_point.dart';
import '../services/api_service.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import '../widgets/destination_card.dart';
import '../widgets/quick_tile.dart';
import '../widgets/slide_route.dart';
import '../widgets/start_location_sheet.dart';
import '../widgets/state_views.dart';
import 'navigation_screen.dart';
import 'scan_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = const ApiService();
  final _controller = TextEditingController(); // owns the text in the search box

  List<Destination> _all = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  String _category = 'All';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Loads every destination once. Filtering while typing happens locally.
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

  void _open(Destination destination) {
    Navigator.of(context).push(slideRoute(NavigationScreen(destination: destination)));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // "From" and "to" as two stations on one line: the first field is
          // where you are, the second is where you want to go.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: 28,
                  height: 126, // 56 + 14 + 56: the two fields and the gap
                  child: CustomPaint(painter: _JourneyRailPainter()),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    children: [
                      const _SourceField(),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 56,
                        child: TextField(
                          controller: _controller,
                          textInputAction: TextInputAction.search,
                          onChanged: (value) => setState(() => _query = value),
                          decoration: InputDecoration(
                            hintText: 'Where do you want to go?',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: () {
                                      _controller.clear(); // clears the text in the box
                                      setState(() => _query = ''); // and our copy of it
                                    },
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: categories.length,
              separatorBuilder: (context, index) => const SizedBox(width: 8),
              itemBuilder: (context, i) => _CategoryChip(
                label: categories[i],
                selected: categories[i] == _category,
                onTap: () => setState(() => _category = categories[i]),
              ),
            ),
          ),
          Expanded(
            // Rebuild when saved places or recents change.
            child: ListenableBuilder(
              listenable: Listenable.merge([AppState.favorites, AppState.recents]),
              builder: (context, _) => _content(text),
            ),
          ),
        ],
      ),
    );
  }

  /// Saved places first, then recent ones, then the defaults. Max six.
  List<Destination> _quickList() {
    final byId = {for (final d in _all) d.id: d};
    final ids = <String>[
      ...AppState.favorites.value,
      ...AppState.recents.value,
      for (final d in _all) d.id,
    ];
    final seen = <String>{};
    final result = <Destination>[];
    for (final id in ids) {
      final d = byId[id];
      if (d != null && seen.add(id)) result.add(d);
      if (result.length == 6) break;
    }
    return result;
  }

  Widget _content(TextTheme text) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: LoadingList(),
      );
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _retry);
    }

    final results = _all
        .where((d) =>
            d.matches(_query) &&
            (_category == 'All' || categoryOfType(d.type) == _category))
        .toList();
    final filtering = _query.trim().isNotEmpty || _category != 'All';

    // Group by building, keeping the order they first appear in.
    final groups = <String, List<Destination>>{};
    for (final d in results) {
      groups.putIfAbsent(d.building, () => []).add(d);
    }
    final quick = _quickList();

    // Pull down to reload. AlwaysScrollable lets the pull work on short lists.
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        children: [
          if (!filtering && quick.isNotEmpty) ...[
            Text('Quick access', style: text.titleMedium),
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: quick.length,
                separatorBuilder: (context, index) => const SizedBox(width: 12),
                itemBuilder: (context, i) =>
                    QuickTile(destination: quick[i], onTap: () => _open(quick[i])),
              ),
            ),
            const SizedBox(height: 28),
          ],
          if (filtering)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '${results.length} ${results.length == 1 ? 'result' : 'results'}',
                style: text.titleMedium,
              ),
            ),
          if (results.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: EmptyView(
                icon: Icons.search_off,
                title: 'No destination found',
                message: 'Try another name, or clear the filter.',
              ),
            )
          else
            for (final entry in groups.entries) ...[
              _GroupHeader(building: entry.key, count: entry.value.length),
              const SizedBox(height: 10),
              for (final d in entry.value)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DestinationCard(
                    destination: d,
                    highlight: _query,
                    onTap: () => _open(d),
                  ),
                ),
              const SizedBox(height: 14),
            ],
        ],
      ),
    );
  }
}

/// The "from" field: shows where you are, and lets you change it by tapping
/// the field or scanning a QR code.
class _SourceField extends StatelessWidget {
  const _SourceField();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return ValueListenableBuilder<StartPoint>(
      valueListenable: AppState.startPoint,
      builder: (context, start, _) {
        return SizedBox(
          height: 56,
          child: Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: AppColors.mist),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => showStartLocationSheet(context),
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Where are you now?',
                            style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                          ),
                          Text(
                            start.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleMedium,
                          ),
                        ],
                      ),
                    ),
                    const Text(
                      'Change',
                      style: TextStyle(
                        color: AppColors.academic,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Scan a QR code',
                      color: AppColors.academic,
                      icon: const Icon(Icons.qr_code_scanner),
                      onPressed: () => openScanner(
                        context,
                        onManual: () => showStartLocationSheet(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A blue line joining two stations: you (hollow) and your destination (solid).
class _JourneyRailPainter extends CustomPainter {
  const _JourneyRailPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    const top = 28.0; // centre of the first field
    final bottom = size.height - 28; // centre of the second field

    canvas.drawLine(
      Offset(x, top),
      Offset(x, bottom),
      Paint()
        ..color = AppColors.academic
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );

    // Start: white dot with a blue ring.
    canvas.drawCircle(Offset(x, top), 9, Paint()..color = Colors.white);
    canvas.drawCircle(
      Offset(x, top),
      9,
      Paint()
        ..color = AppColors.academic
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );

    // Destination: solid dot with a soft halo.
    canvas.drawCircle(
      Offset(x, bottom),
      14,
      Paint()..color = AppColors.academic.withValues(alpha: 0.18),
    );
    canvas.drawCircle(Offset(x, bottom), 8, Paint()..color = AppColors.academic);
  }

  @override
  bool shouldRepaint(_JourneyRailPainter old) => false;
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.ink : Colors.white,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? AppColors.ink : AppColors.mist),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Building name with a metro "station" dot in the building's line colour.
class _GroupHeader extends StatelessWidget {
  final String building;
  final int count;

  const _GroupHeader({required this.building, required this.count});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final line = lineColorForBuilding(building);

    return Row(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: line, width: 4),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(building, style: text.titleMedium)),
        Text(
          '$count',
          style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
        ),
      ],
    );
  }
}
