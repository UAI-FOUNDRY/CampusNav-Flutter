import 'package:flutter/material.dart';
import '../models/destination.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';

/// Compact tile for the "Quick access" row on the home screen.
class QuickTile extends StatelessWidget {
  final Destination destination;
  final VoidCallback onTap;

  const QuickTile({super.key, required this.destination, required this.onTap});

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
                Padding(
                  padding: const EdgeInsets.all(12),
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
                      const SizedBox(height: 10),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
