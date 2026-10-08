import 'package:flutter/material.dart';
import '../data/mock_campus.dart';
import '../models/start_point.dart';
import '../screens/scan_screen.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import 'app_card.dart';

/// Lets the user say where they are. Scanning a QR code will call the same
/// `AppState.setStart(...)` later.
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
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              onTap: () {
                // Close this sheet, then open the scanner. The navigator's
                // own context stays valid after the sheet is gone.
                final navigator = Navigator.of(context);
                navigator.pop();
                openScanner(
                  navigator.context,
                  onManual: () => showStartLocationSheet(navigator.context),
                );
              },
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.academic.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.qr_code_scanner, color: AppColors.academic),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Scan a QR code', style: text.titleMedium),
                        Text(
                          'Fastest: scan the code on the nearest signboard',
                          style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: AppColors.inkMuted),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('Or pick a landmark', style: text.titleMedium),
            const SizedBox(height: 12),
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
        AppState.setStart(point);
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
