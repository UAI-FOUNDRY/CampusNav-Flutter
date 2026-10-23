import 'dart:async';

import 'package:flutter/material.dart';
import 'data/deep_link.dart';
import 'screens/app_shell.dart';
import 'screens/deep_link_screen.dart';
import 'services/api_service.dart';
import 'state/app_state.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The free server sleeps when nobody uses it: start waking it right away,
  // while the app reads its saved data.
  unawaited(ApiService.wakeUp());
  await AppState.load(); // read saved places and settings before the first screen
  runApp(const CampusNavApp());
}

class CampusNavApp extends StatelessWidget {
  const CampusNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'UAI Navigation', // the name in the recent-apps screen
      theme: AppTheme.light(),
      // Over every screen: a note while the server wakes up.
      builder: (context, child) => Stack(
        children: [
          if (child != null) child,
          const _WakingNote(),
        ],
      ),
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

/// "Waking up the campus server" while it takes a while (the free server
/// sleeps after 15 minutes without use and needs up to a minute).
class _WakingNote extends StatelessWidget {
  const _WakingNote();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ApiService.waking,
      builder: (context, waking, _) => IgnorePointer(
        child: AnimatedOpacity(
          opacity: waking ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                child: Semantics(
                  liveRegion: true,
                  child: Material(
                    color: AppColors.ink,
                    elevation: 4,
                    borderRadius: BorderRadius.circular(24),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          ),
                          SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              'Waking up the campus server, this can take up to a minute',
                              style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
