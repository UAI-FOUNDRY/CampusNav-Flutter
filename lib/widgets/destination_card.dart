import 'package:flutter/material.dart';
import '../models/destination.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import 'pill.dart';

/// One row in the destination list. The coloured stripe on the left is the
/// building's "metro line".
class DestinationCard extends StatelessWidget {
  final Destination destination;
  final VoidCallback onTap;

  const DestinationCard({
    super.key,
    required this.destination,
    required this.onTap,
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
                              Text(destination.name, style: text.titleMedium),
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
