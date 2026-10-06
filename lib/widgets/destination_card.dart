import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class DestinationCard extends StatelessWidget {
  final String name;
  final String building;
  final String floor;
  final IconData icon;
  final Color lineColor;
  final VoidCallback onTap;

  const DestinationCard({
    super.key,
    required this.name,
    required this.building,
    required this.floor,
    required this.icon,
    required this.lineColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),

      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,

        child: Padding(
          padding: const EdgeInsets.all(16),

          child: Row(
            children: [
              // Metro line
              Container(
                width: 6,
                height: 58,

                decoration: BoxDecoration(
                  color: lineColor,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),

              const SizedBox(width: 14),

              // Destination icon
              Container(
                width: 46,
                height: 46,

                decoration: BoxDecoration(
                  color: lineColor.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),

                child: Icon(
                  icon,
                  color: lineColor,
                  size: 24,
                ),
              ),

              const SizedBox(width: 14),

              // Destination information
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    Text(
                      name,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium,
                    ),

                    const SizedBox(height: 4),

                    Text(
                      '$building • $floor',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(
                            color: AppColors.inkMuted,
                          ),
                    ),
                  ],
                ),
              ),

              Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: AppColors.inkMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}