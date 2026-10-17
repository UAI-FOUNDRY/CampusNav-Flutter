import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/campus.dart';
import '../models/start_point.dart';
import '../screens/scan_screen.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';

/// "Where are you now?": GPS, QR code, or any place / spot on campus.
Future<void> showStartLocationSheet(BuildContext context) {
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
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => _StartSheet(scroll: scroll),
    ),
  );
}

// One row of the list: a section title or a start point.
sealed class _Item {}

class _Header extends _Item {
  final String title;
  final int? count;
  _Header(this.title, [this.count]);
}

class _Row extends _Item {
  final StartPoint point;
  final bool showHint; // hide the hint when the section title already says it
  _Row(this.point, {this.showHint = true});
}

class _StartSheet extends StatefulWidget {
  final ScrollController scroll;

  const _StartSheet({required this.scroll});

  @override
  State<_StartSheet> createState() => _StartSheetState();
}

class _StartSheetState extends State<_StartSheet> {
  final _search = TextEditingController();
  String _query = '';
  List<StartPoint> _all = const [];
  bool _loading = true;

  bool _locating = false;
  LocateResult? _problem;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final catalog = await const ApiService().loadCatalog();
      if (!mounted) return;
      setState(() {
        _all = catalog.starts.isNotEmpty ? catalog.starts : Campus.startPoints;
        _loading = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _all = Campus.startPoints; // the popular few still work offline
        _loading = false;
      });
    }
  }

  void _pick(StartPoint point) {
    HapticFeedback.selectionClick();
    AppState.setStart(point);
    Navigator.of(context).pop();
  }

  void _scan() {
    final navigator = Navigator.of(context);
    navigator.pop();
    openScanner(
      navigator.context,
      onManual: () => showStartLocationSheet(navigator.context),
    );
  }

  Future<void> _useLocation() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _locating = true;
      _problem = null;
    });
    final result = await LocationService.locate(_all);
    if (!mounted) return;
    final point = result.point;
    if (point == null) {
      HapticFeedback.lightImpact();
      setState(() {
        _locating = false;
        _problem = result;
      });
      return;
    }

    HapticFeedback.mediumImpact();
    AppState.setStart(point);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    navigator.pop();
    final rough = (point.accuracy ?? 0) > 40;
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: rough ? 6 : 3),
      content: Text(rough
          ? '${result.message} GPS is rough here (±${point.accuracy!.round()} m): '
              'for an exact start, scan the QR code on a nearby sign.'
          : result.message),
      action: rough
          ? SnackBarAction(
              label: 'Scan',
              onPressed: () => openScanner(
                navigator.context,
                onManual: () => showStartLocationSheet(navigator.context),
              ),
            )
          : null,
    ));
  }

  /// The fix for a location problem, if there is one.
  (String, VoidCallback)? _fixFor(LocateProblem problem) => switch (problem) {
        LocateProblem.serviceOff => ('Turn on location', LocationService.openLocationSettings),
        LocateProblem.deniedForever => ('Open settings', LocationService.openAppSettings),
        LocateProblem.denied || LocateProblem.timeout || LocateProblem.failed =>
          ('Try again', _useLocation),
        LocateProblem.offCampus || LocateProblem.noMap => null,
      };

  // ---- the list ----

  /// The popular start points, with the details from the full list.
  List<StartPoint> get _popular {
    final byId = {for (final s in _all) s.id: s};
    return [for (final p in Campus.startPoints) byId[p.id] ?? p];
  }

  List<_Item> _items() {
    final q = _query.trim();
    if (q.isNotEmpty) {
      final seen = <String>{};
      final hits = [
        for (final s in [..._popular, ..._all])
          if (s.matches(q) && seen.add(s.id)) s,
      ];
      return [
        _Header(hits.isEmpty ? 'No matches' : '${hits.length} ${hits.length == 1 ? 'match' : 'matches'}'),
        for (final s in hits) _Row(s),
      ];
    }

    final items = <_Item>[];
    final recent = [
      for (final r in AppState.recentStarts.value)
        if (!Campus.startPoints.any((p) => p.id == r.id)) r,
    ];
    if (recent.isNotEmpty) {
      items.add(_Header('Recent'));
      items.addAll([for (final r in recent.take(3)) _Row(r)]);
    }
    items.add(_Header('Popular'));
    items.addAll([for (final p in _popular) _Row(p)]);

    // Every place and spot, by area: outside first, then each floor.
    final groups = <String, List<StartPoint>>{};
    for (final s in _all) {
      final g = s.group;
      if (g == null) continue;
      groups.putIfAbsent(g, () => []).add(s);
    }
    final order = groups.keys.toList()
      ..sort((a, b) {
        if (a == 'Outside') return -1;
        if (b == 'Outside') return 1;
        final fa = groups[a]!.first.floor ?? 0;
        final fb = groups[b]!.first.floor ?? 0;
        return fa != fb ? fa.compareTo(fb) : a.compareTo(b);
      });
    for (final g in order) {
      final list = groups[g]!..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      items.add(_Header(g, list.length));
      // The section says where; show the hint only when it adds something
      // ("Inside the Library · ...").
      items.addAll([for (final s in list) _Row(s, showHint: s.hint != g)]);
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return ValueListenableBuilder<StartPoint>(
      valueListenable: AppState.startPoint,
      builder: (context, current, _) {
        final items = _loading ? const <_Item>[] : _items();
        return ListView.builder(
          controller: widget.scroll,
          padding: const EdgeInsets.only(bottom: 32),
          itemCount: 1 + (_loading ? 1 : items.length) + (_isEmptySearch(items) ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == 0) return _top(text, current);
            if (_loading) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (i - 1 >= items.length) return _emptySearch(text);
            final item = items[i - 1];
            return switch (item) {
              _Header(:final title, :final count) => _SectionTitle(title: title, count: count),
              _Row(:final point, :final showHint) => _StartRow(
                  point: point,
                  showHint: showHint,
                  selected: !current.live && point.id == current.id,
                  onTap: () => _pick(point),
                ),
            };
          },
        );
      },
    );
  }

  bool _isEmptySearch(List<_Item> items) =>
      !_loading && _query.trim().isNotEmpty && items.length <= 1;

  Widget _top(TextTheme text, StartPoint current) {
    final problem = _problem;
    final fix = problem?.problem == null ? null : _fixFor(problem!.problem!);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
          Text('Where are you now?', style: text.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Every route starts here. Use your location, scan a sign, or pick a place.',
            style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: 18),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _ActionTile(
                    icon: Icons.my_location,
                    title: current.live ? 'Update location' : 'Use my location',
                    subtitle: _locating
                        ? 'Finding you…'
                        : current.live
                            ? current.hint
                            : 'GPS · best outdoors',
                    busy: _locating,
                    active: current.live,
                    onTap: _locating ? null : _useLocation,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ActionTile(
                    icon: Icons.qr_code_scanner,
                    title: 'Scan a QR code',
                    subtitle: 'Exact · on signboards',
                    onTap: _scan,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: problem == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _ProblemBanner(
                      message: problem.message,
                      actionLabel: fix?.$1,
                      onAction: fix?.$2,
                      onClose: () => setState(() => _problem = null),
                    ),
                  ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search rooms, gates, lifts, landmarks',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
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
        ],
      ),
    );
  }

  Widget _emptySearch(TextTheme text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
      child: Text(
        'Nothing called "${_query.trim()}". Try a room number, a block ("Block A"), '
        'or something nearby like "lift" or "stairs".',
        textAlign: TextAlign.center,
        style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
      ),
    );
  }
}

// ---- pieces ----

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool busy;
  final bool active;
  final VoidCallback? onTap;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.busy = false,
    this.active = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const accent = AppColors.academic;
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: Material(
        color: active ? accent.withValues(alpha: 0.08) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: active ? accent : AppColors.mist, width: active ? 1.5 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: busy
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : Icon(icon, color: accent, size: 22),
                ),
                const SizedBox(height: 10),
                Text(title, style: text.titleSmall),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProblemBanner extends StatelessWidget {
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onClose;

  const _ProblemBanner({
    required this.message,
    required this.onClose,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF4E5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFF5C77E)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.location_disabled, size: 20, color: Color(0xFF8A5300)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: text.bodyMedium?.copyWith(color: AppColors.ink)),
                  if (actionLabel != null)
                    TextButton(
                      onPressed: onAction,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(44, 40),
                        foregroundColor: const Color(0xFF8A5300),
                      ),
                      child: Text(actionLabel!),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, size: 18, color: AppColors.inkMuted),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final int? count;

  const _SectionTitle({required this.title, this.count});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: text.labelLarge?.copyWith(color: AppColors.inkMuted, letterSpacing: 0.2),
              ),
            ),
            if (count != null)
              Text('$count', style: text.labelLarge?.copyWith(color: AppColors.inkMuted)),
          ],
        ),
      ),
    );
  }
}

class _StartRow extends StatelessWidget {
  final StartPoint point;
  final bool showHint;
  final bool selected;
  final VoidCallback onTap;

  const _StartRow({
    required this.point,
    required this.showHint,
    required this.selected,
    required this.onTap,
  });

  (IconData, Color) get _look => switch (point.type) {
        'stairs' => (Icons.stairs_outlined, AppColors.ink),
        'lift' => (Icons.elevator_outlined, AppColors.ink),
        'entrance' || 'gate' => (Icons.door_front_door_outlined, AppColors.ink),
        _ => (iconForType(point.type), colorForType(point.type)),
      };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (icon, color) = _look;
    return Semantics(
      button: true,
      selected: selected,
      label: '${point.name}, ${point.hint}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 21, color: lineInk(color)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        point.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(
                          color: selected ? AppColors.academic : AppColors.ink,
                        ),
                      ),
                      if (showHint && point.hint.isNotEmpty)
                        Text(
                          point.hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                        ),
                    ],
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.check_circle, color: AppColors.academic, size: 22),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
