import 'package:flutter/material.dart';
import '../models/destination.dart';
import '../models/start_point.dart';
import '../services/api_service.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import '../widgets/destination_card.dart';
import '../widgets/quick_tile.dart';
import '../widgets/start_location_sheet.dart';
import '../widgets/state_views.dart';
import 'navigation_screen.dart';

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
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NavigationScreen(destination: destination)),
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
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Campus Navigation',
                        style: text.titleMedium?.copyWith(color: AppColors.inkMuted),
                      ),
                      const SizedBox(height: 2),
                      Text('Where to?', style: text.headlineSmall),
                    ],
                  ),
                ),
                const _StartChip(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Search rooms, labs, facilities',
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
          Expanded(child: _content(text)),
        ],
      ),
    );
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
    final quick = _all.take(4).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: [
        if (!filtering && quick.isNotEmpty) ...[
          Text('Quick access', style: text.titleMedium),
          const SizedBox(height: 12),
          SizedBox(
            height: 108,
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
                child: DestinationCard(destination: d, onTap: () => _open(d)),
              ),
            const SizedBox(height: 14),
          ],
      ],
    );
  }
}

/// "From: Main Gate" pill. Opens the start-location sheet.
class _StartChip extends StatelessWidget {
  const _StartChip();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<StartPoint>(
      valueListenable: AppState.startPoint,
      builder: (context, start, _) {
        return Material(
          color: Colors.white,
          shape: const StadiumBorder(side: BorderSide(color: AppColors.mist)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => showStartLocationSheet(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.my_location, size: 16, color: AppColors.academic),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110),
                    child: Text(
                      start.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const Icon(Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
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
