import 'package:flutter/material.dart';

import '../models/destination.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';

/// The card that slides up when a place is picked on the map: what it is,
/// where it is, and a big "Directions" button. Picking first and confirming
/// second means a mis-tap on a crowded plan does not start a route.
class PlaceCard extends StatelessWidget {
  final Destination destination;
  final VoidCallback onDirections;
  final VoidCallback onClose;

  const PlaceCard({
    super.key,
    required this.destination,
    required this.onDirections,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = destination;
    final line = lineColorForBuilding(d.building);

    return Material(
      color: Colors.white,
      elevation: 8,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 10, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(
                    color: line.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(iconForType(d.type), color: lineInk(line), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.name,
                        style: text.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        d.locationLine,
                        style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, color: AppColors.inkMuted),
                  onPressed: onClose,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: onDirections,
                  icon: const Icon(Icons.directions_walk),
                  label: const Text('Directions'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.academic,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
