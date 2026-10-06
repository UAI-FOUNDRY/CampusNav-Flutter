import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../widgets/route_strip.dart';

class NavigationScreen extends StatelessWidget {
  final String destination;

  const NavigationScreen({
    super.key,
    required this.destination,
  });

  @override
  Widget build(BuildContext context) {
    final route = [
      const RouteStop(
        title: 'You are here',
        subtitle: 'Current location',
        distance: 'Start',
        icon: Icons.my_location,
        color: AppColors.academic,
      ),

      const RouteStop(
        title: 'Main Junction',
        subtitle: 'Walk straight',
        distance: '42 m',
        icon: Icons.circle,
        color: AppColors.academic,
      ),

      const RouteStop(
        title: 'Stairs',
        subtitle: 'Take stairs to Floor 2',
        distance: '18 m',
        icon: Icons.stairs,
        color: AppColors.mainBuilding,
      ),

      RouteStop(
        title: destination,
        subtitle: 'Your destination',
        distance: 'Arrive',
        icon: Icons.location_on,
        color: AppColors.academic,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(destination),
      ),

      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            20,
            10,
            20,
            20,
          ),

          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,

            children: [
              // ==========================================
              // ROUTE SUMMARY
              // ==========================================

              Text(
                'Your route',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall,
              ),

              const SizedBox(height: 4),

              Text(
                'Academic Building • Floor 2',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(
                      color: AppColors.inkMuted,
                    ),
              ),

              const SizedBox(height: 20),

              // ==========================================
              // DISTANCE
              // ==========================================

              Row(
                crossAxisAlignment:
                    CrossAxisAlignment.end,

                children: [
                  Text(
                    '143',
                    style: Theme.of(context)
                        .textTheme
                        .displaySmall,
                  ),

                  const SizedBox(width: 6),

                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: 5),

                    child: Text(
                      'm',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(
                            color:
                                AppColors.inkMuted,
                          ),
                    ),
                  ),

                  const SizedBox(width: 20),

                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: 7),

                    child: Text(
                      '≈ 2 min',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(
                            color:
                                AppColors.inkMuted,
                          ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // ==========================================
              // ROUTE
              // ==========================================

              Expanded(
                child: RouteStrip(
                  stops: route,
                ),
              ),

              // ==========================================
              // CURRENT INSTRUCTION
              // ==========================================

              Container(
                padding: const EdgeInsets.all(16),

                decoration: BoxDecoration(
                  color: Colors.white,

                  borderRadius:
                      BorderRadius.circular(18),

                  border: Border.all(
                    color: AppColors.mist,
                  ),
                ),

                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,

                      decoration: BoxDecoration(
                        color: AppColors.academic
                            .withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),

                      child: const Icon(
                        Icons.arrow_upward,
                        color:
                            AppColors.academic,
                      ),
                    ),

                    const SizedBox(width: 14),

                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,

                        children: [
                          Text(
                            'Walk straight',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium,
                          ),

                          const SizedBox(height: 3),

                          Text(
                            '42 meters to Main Junction',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color:
                                      AppColors.inkMuted,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}