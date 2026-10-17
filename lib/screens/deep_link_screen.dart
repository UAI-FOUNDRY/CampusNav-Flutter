import 'package:flutter/material.dart';

import '../data/campus.dart';
import '../data/deep_link.dart';
import '../models/destination.dart';
import '../services/api_service.dart';
import '../state/app_state.dart';
import '../widgets/state_views.dart';
import 'navigation_screen.dart';

/// Opens a [DeepLink]: sets the start if the link has one, finds the place,
/// then replaces itself with the route to it.
class DeepLinkScreen extends StatefulWidget {
  final DeepLink link;

  const DeepLinkScreen({super.key, required this.link});

  @override
  State<DeepLinkScreen> createState() => _DeepLinkScreenState();
}

class _DeepLinkScreenState extends State<DeepLinkScreen> {
  final _api = const ApiService();
  ApiException? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    setState(() => _error = null);
    final link = widget.link;

    final fromId = link.from;
    if (fromId != null) {
      final start = Campus.startPointFromCode(fromId);
      if (start != null) AppState.setStart(start);
    }

    final toId = link.to;
    if (toId == null) {
      // Only "you are here": back to the app with a note.
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(content: Text('You are at ${AppState.startPoint.value.name}')),
      );
      return;
    }

    try {
      final catalog = await _api.loadCatalog();
      Destination? place;
      for (final d in catalog.places) {
        if (d.id == toId) {
          place = d;
          break;
        }
      }
      if (!mounted) return;
      if (place == null) {
        setState(() => _error = const ApiException(
              'This link points to a place the app does not know. '
              'It may have been renamed: search for it instead.',
              ApiErrorKind.notFound,
            ));
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => NavigationScreen(destination: place!)),
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('Opening link')),
      body: error == null
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Finding the place…'),
                ],
              ),
            )
          : ErrorView(
              message: error.message,
              kind: error.kind,
              onRetry: _open,
              actionLabel: 'Search instead',
              actionIcon: Icons.search,
              onAction: () => Navigator.of(context).pop(),
            ),
    );
  }
}

/// Shown for a link the app does not understand.
class UnknownLinkScreen extends StatelessWidget {
  const UnknownLinkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Link not recognised')),
      body: ErrorView(
        message: 'This link is not a campus navigation link.',
        kind: ApiErrorKind.notFound,
        onRetry: () => Navigator.of(context).pop(),
        actionLabel: 'Open the app',
        actionIcon: Icons.home_outlined,
        onAction: () => Navigator.of(context).pop(),
      ),
    );
  }
}
