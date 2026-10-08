import 'package:flutter/material.dart';
import '../models/destination.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import 'highlight_text.dart';
import 'pill.dart';

/// One row in the destination list. The coloured stripe on the left is the
/// building's "metro line".
class DestinationCard extends StatelessWidget {
  final Destination destination;
  final VoidCallback onTap;

  /// The current search text; matches are highlighted in the name.
  final String highlight;

  const DestinationCard({
    super.key,
    required this.destination,
    required this.onTap,
    this.highlight = '',
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final line = lineColorForBuilding(destination.building);

    return Material(
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
          child: IntrinsicHeight(
            child: Row(
              children: [
                Container(width: 6, color: line),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(iconForType(destination.type), color: lineInk(line), size: 26),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: HighlightText(
                                      text: destination.name,
                                      query: highlight,
                                      style: text.titleMedium,
                                    ),
                                  ),
                                  _SavedStar(id: destination.id),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                destination.building,
                                style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Pill(text: floorLabel(destination.floor), color: line),
                      ],
                    ),
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

/// A small star next to the name when the place is saved.
class _SavedStar extends StatelessWidget {
  final String id;
  const _SavedStar({required this.id});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: AppState.favorites,
      builder: (context, favorites, _) {
        if (!favorites.contains(id)) return const SizedBox.shrink();
        return const Padding(
          padding: EdgeInsets.only(left: 6),
          child: Icon(Icons.star, size: 16, color: AppColors.sports),
        );
      },
    );
  }
}
