import 'package:flutter/material.dart';
import 'data/deep_link.dart';
import 'screens/app_shell.dart';
import 'screens/deep_link_screen.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppState.load(); // read saved places and settings before the first screen
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
      // Opened from a link (QR poster, campusnav://campus/to/<place>): the app
      // starts on its normal tabs with the route to that place on top, so Back
      // lands somewhere sensible.
      onGenerateInitialRoutes: (initialRoute) {
        final link = DeepLink.parse(initialRoute);
        return [
          MaterialPageRoute<void>(builder: (_) => const AppShell()),
          if (link != null) MaterialPageRoute<void>(builder: (_) => DeepLinkScreen(link: link)),
        ];
      },
      // A link opened while the app is already running.
      onGenerateRoute: (settings) {
        final name = settings.name ?? '/';
        if (name == '/') {
          return MaterialPageRoute<void>(settings: settings, builder: (_) => const AppShell());
        }
        final link = DeepLink.parse(name);
        if (link == null) return null;
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => DeepLinkScreen(link: link),
        );
      },
      onUnknownRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => const UnknownLinkScreen(),
      ),
    );
  }
}
