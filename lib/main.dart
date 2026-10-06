import 'package:flutter/material.dart';

import 'models/destination.dart';
import 'screens/navigation_screen.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'widgets/destination_card.dart';

void main() {
  runApp(const CampusNavApp());
}

class CampusNavApp extends StatelessWidget {
  const CampusNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Campus Navigation',
      theme: AppTheme.light(),
      home: const HomeScreen(),
    );
  }
}

// ============================================================
// HOME SCREEN
// ============================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ==========================================================
  // TEMPORARY LOCAL DESTINATIONS
  // ==========================================================

  static const List<Destination> destinations = [
    Destination(
      id: 'library',
      name: 'Library',
      building: 'Academic Building',
      floor: 1,
      type: 'library',
    ),

    Destination(
      id: 'ai_lab',
      name: 'AI Lab',
      building: 'Academic Building',
      floor: 2,
      type: 'lab',
    ),

    Destination(
      id: 'cafeteria',
      name: 'Cafeteria',
      building: 'Main Building',
      floor: 1,
      type: 'cafeteria',
    ),

    Destination(
      id: 'sports',
      name: 'Sports Complex',
      building: 'Sports Building',
      floor: 0,
      type: 'sports',
    ),
  ];

  // What the user has typed.
  String searchQuery = '';

  @override
  Widget build(BuildContext context) {
    // ========================================================
    // FILTER DESTINATIONS
    // ========================================================

    final filteredDestinations =
        destinations.where((destination) {
      final query = searchQuery.toLowerCase().trim();

      if (query.isEmpty) {
        return true;
      }

      return destination.name
              .toLowerCase()
              .contains(query) ||
          destination.building
              .toLowerCase()
              .contains(query) ||
          destination.type
              .toLowerCase()
              .contains(query) ||
          destination.floor
              .toString()
              .contains(query);
    }).toList();

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            20,
            20,
            20,
            0,
          ),

          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,

            children: [
              // =================================================
              // HEADER
              // =================================================

              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,

                      children: [
                        Text(
                          'Campus Navigation',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                color:
                                    AppColors.inkMuted,
                              ),
                        ),

                        const SizedBox(height: 4),

                        Text(
                          'Where do you want to go?',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall,
                        ),
                      ],
                    ),
                  ),

                  Container(
                    width: 42,
                    height: 42,

                    decoration: BoxDecoration(
                      color: AppColors.academic
                          .withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                    ),

                    child: const Icon(
                      Icons.my_location,
                      color:
                          AppColors.academic,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // =================================================
              // SEARCH BAR
              // =================================================

              TextField(
                onChanged: (value) {
                  setState(() {
                    searchQuery = value;
                  });
                },

                decoration: InputDecoration(
                  hintText:
                      'Search rooms, labs, facilities...',
                  prefixIcon:
                      const Icon(Icons.search),

                  suffixIcon:
                      searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(
                                Icons.clear,
                              ),

                              onPressed: () {
                                setState(() {
                                  searchQuery = '';
                                });
                              },
                            )
                          : null,
                ),
              ),

              const SizedBox(height: 28),

              // =================================================
              // SEARCH RESULTS / QUICK ACCESS
              // =================================================

              if (searchQuery.isEmpty) ...[
                Text(
                  'Quick access',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium,
                ),

                const SizedBox(height: 12),

                SizedBox(
                  height: 104,

                  child: Row(
                    children: [
                      Expanded(
                        child: _QuickDestination(
                          destination:
                              destinations[0],
                          color:
                              AppColors.academic,
                          icon:
                              Icons.local_library,
                        ),
                      ),

                      const SizedBox(width: 12),

                      Expanded(
                        child: _QuickDestination(
                          destination:
                              destinations[1],
                          color:
                              AppColors.academic,
                          icon: Icons.science,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 28),

                Text(
                  'Popular destinations',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium,
                ),

                const SizedBox(height: 12),
              ] else ...[
                Text(
                  '${filteredDestinations.length} '
                  '${filteredDestinations.length == 1 ? 'result' : 'results'}',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium,
                ),

                const SizedBox(height: 12),
              ],

              // =================================================
              // DESTINATION LIST
              // =================================================

              Expanded(
                child:
                    filteredDestinations.isEmpty
                        ? _EmptySearch()
                        : ListView.separated(
                            itemCount:
                                filteredDestinations
                                    .length,

                            separatorBuilder:
                                (context, index) {
                              return const SizedBox(
                                height: 12,
                              );
                            },

                            itemBuilder:
                                (context, index) {
                              final destination =
                                  filteredDestinations[
                                      index];

                              return DestinationCard(
                                name:
                                    destination.name,

                                building:
                                    destination
                                        .building,

                                floor:
                                    _floorName(
                                  destination.floor,
                                ),

                                icon:
                                    _iconForType(
                                  destination.type,
                                ),

                                lineColor:
                                    _colorForType(
                                  destination.type,
                                ),

                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder:
                                          (context) =>
                                              NavigationScreen(
                                        destination:
                                            destination
                                                .name,
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),

      // =======================================================
      // BOTTOM NAVIGATION
      // =======================================================

      bottomNavigationBar:
          NavigationBar(
        selectedIndex: 0,

        destinations: const [
          NavigationDestination(
            icon:
                Icon(Icons.home_outlined),
            selectedIcon:
                Icon(Icons.home),
            label: 'Home',
          ),

          NavigationDestination(
            icon:
                Icon(Icons.map_outlined),
            selectedIcon:
                Icon(Icons.map),
            label: 'Map',
          ),

          NavigationDestination(
            icon:
                Icon(Icons.settings_outlined),
            selectedIcon:
                Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // FLOOR NAME
  // ==========================================================

  String _floorName(int floor) {
    if (floor == 0) {
      return 'Ground Floor';
    }

    return 'Floor $floor';
  }

  // ==========================================================
  // ICON
  // ==========================================================

  IconData _iconForType(String type) {
    switch (type) {
      case 'library':
        return Icons.local_library;

      case 'lab':
        return Icons.science;

      case 'cafeteria':
        return Icons.restaurant;

      case 'sports':
        return Icons.sports_soccer;

      default:
        return Icons.location_on;
    }
  }

  // ==========================================================
  // METRO LINE COLOR
  // ==========================================================

  Color _colorForType(String type) {
    switch (type) {
      case 'library':
      case 'lab':
        return AppColors.academic;

      case 'cafeteria':
        return AppColors.mainBuilding;

      case 'sports':
        return AppColors.sports;

      default:
        return AppColors.academic;
    }
  }
}

// ============================================================
// QUICK DESTINATION
// ============================================================

class _QuickDestination
    extends StatelessWidget {
  final Destination destination;
  final Color color;
  final IconData icon;

  const _QuickDestination({
    required this.destination,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius:
          BorderRadius.circular(18),

      child: InkWell(
        borderRadius:
            BorderRadius.circular(18),

        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  NavigationScreen(
                destination:
                    destination.name,
              ),
            ),
          );
        },

        child: Container(
          padding:
              const EdgeInsets.all(14),

          decoration: BoxDecoration(
            borderRadius:
                BorderRadius.circular(18),

            border: Border.all(
              color: AppColors.mist,
            ),
          ),

          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,

                decoration: BoxDecoration(
                  color: color.withValues(
                    alpha: 0.10,
                  ),
                  shape: BoxShape.circle,
                ),

                child: Icon(
                  icon,
                  color: color,
                ),
              ),

              const SizedBox(width: 10),

              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,

                  mainAxisAlignment:
                      MainAxisAlignment.center,

                  children: [
                    Text(
                      destination.name,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium,
                    ),

                    Text(
                      'F${destination.floor}',
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
      ),
    );
  }
}

// ============================================================
// EMPTY SEARCH
// ============================================================

class _EmptySearch
    extends StatelessWidget {
  const _EmptySearch();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment:
            MainAxisAlignment.center,

        children: [
          Icon(
            Icons.search_off,
            size: 64,
            color: AppColors.inkMuted,
          ),

          const SizedBox(height: 16),

          Text(
            'No destination found',
            style: Theme.of(context)
                .textTheme
                .titleMedium,
          ),

          const SizedBox(height: 6),

          Text(
            'Try searching for another room or facility.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(
                  color: AppColors.inkMuted,
                ),
          ),
        ],
      ),
    );
  }
}