import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class RouteStop {
  final String title;
  final String subtitle;
  final String? distance;
  final IconData icon;
  final Color color;

  const RouteStop({
    required this.title,
    required this.subtitle,
    this.distance,
    required this.icon,
    required this.color,
  });
}

class RouteStrip extends StatelessWidget {
  final List<RouteStop> stops;

  const RouteStrip({
    super.key,
    required this.stops,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: stops.length,
      itemBuilder: (context, index) {
        final stop = stops[index];

        final isLast = index == stops.length - 1;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ==========================================
            // METRO LINE
            // ==========================================

            SizedBox(
              width: 42,

              child: Column(
                children: [
                  Container(
                    width: 26,
                    height: 26,

                    decoration: BoxDecoration(
                      color: stop.color,
                      shape: BoxShape.circle,
                    ),

                    child: Icon(
                      stop.icon,
                      color: Colors.white,
                      size: 15,
                    ),
                  ),

                  if (!isLast)
                    Container(
                      width: 4,
                      height: 65,
                      color: stop.color,
                    ),
                ],
              ),
            ),

            const SizedBox(width: 12),

            // ==========================================
            // STOP INFORMATION
            // ==========================================

            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(
                  bottom: 25,
                ),

                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,

                  children: [
                    Text(
                      stop.title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium,
                    ),

                    const SizedBox(height: 3),

                    Text(
                      stop.subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(
                            color: AppColors.inkMuted,
                          ),
                    ),

                    if (stop.distance != null) ...[
                      const SizedBox(height: 3),

                      Text(
                        stop.distance!,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(
                              color: stop.color,
                              fontWeight:
                                  FontWeight.w600,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}