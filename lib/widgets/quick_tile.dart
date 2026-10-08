import 'package:flutter/material.dart';
import '../models/destination.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';

/// Compact tile for the "Quick access" row on the home screen.
/// The band at the bottom shows the walking time from where you are.
class QuickTile extends StatelessWidget {
  final Destination destination;
  final VoidCallback onTap;

  /// Walking minutes from the user's location. Null while unknown.
  final int? minutes;

  const QuickTile({
    super.key,
    required this.destination,
    required this.onTap,
    this.minutes,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final line = lineColorForBuilding(destination.building);

    return SizedBox(
      width: 150,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.mist),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 5, color: line),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(iconForType(destination.type), color: lineInk(line), size: 24),
                            const Spacer(),
                            ValueListenableBuilder<List<String>>(
                              valueListenable: AppState.favorites,
                              builder: (context, favorites, _) =>
                                  favorites.contains(destination.id)
                                      ? const Icon(Icons.star, size: 16, color: AppColors.sports)
                                      : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          destination.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium,
                        ),
                        Text(
                          floorLabel(destination.floor),
                          style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                        ),
                      ],
                    ),
                  ),
                ),
                if (minutes != null)
                  Container(
                    width: double.infinity,
                    color: line.withValues(alpha: 0.12),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: Row(
                      children: [
                        Icon(Icons.directions_walk, size: 15, color: lineInk(line)),
                        const SizedBox(width: 4),
                        Text(
                          '$minutes min walk',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: lineInk(line),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
