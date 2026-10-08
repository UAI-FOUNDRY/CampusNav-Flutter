import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../widgets/start_location_sheet.dart';
import 'home_screen.dart';
import 'map_screen.dart';

/// The bottom navigation bar and the screens it switches between.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // First launch: ask where the user is before they search anything.
    if (AppState.firstRun) {
      AppState.firstRun = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showStartLocationSheet(context).then((_) {
          // Remember the choice (or the default if they just closed the sheet)
          // so we don't ask again.
          AppState.setStart(AppState.startPoint.value);
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack keeps both tabs alive, so search text and map state
      // survive switching tabs.
      body: IndexedStack(
        index: _index,
        children: const [HomeScreen(), MapScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.search),
            selectedIcon: Icon(Icons.search),
            label: 'Search',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
        ],
      ),
    );
  }
}
