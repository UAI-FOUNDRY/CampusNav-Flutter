import 'package:flutter/material.dart';
import '../data/mock_campus.dart';
import '../models/start_point.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import 'app_card.dart';

/// Lets the user say where they are. Scanning a QR code will call the same
/// `AppState.startPoint.value = ...` later.
Future<void> showStartLocationSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _StartLocationSheet(),
  );
}

class _StartLocationSheet extends StatelessWidget {
  const _StartLocationSheet();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Where are you now?', style: text.headlineSmall),
            const SizedBox(height: 4),
            Text(
              'Pick the closest landmark. Scanning a QR code will set this automatically later.',
              style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<StartPoint>(
              valueListenable: AppState.startPoint,
              builder: (context, current, _) {
                return Column(
                  children: [
                    for (final point in MockCampus.startPoints)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _StartTile(point: point, selected: point.id == current.id),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _StartTile extends StatelessWidget {
  final StartPoint point;
  final bool selected;

  const _StartTile({required this.point, required this.selected});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: () {
        AppState.startPoint.value = point;
        Navigator.of(context).pop();
      },
      child: Row(
        children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            color: selected ? AppColors.academic : AppColors.inkMuted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(point.name, style: text.titleMedium),
                Text(
                  point.hint,
                  style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
