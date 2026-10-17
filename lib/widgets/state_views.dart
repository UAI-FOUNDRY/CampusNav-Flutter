import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';

/// Grey placeholder cards shown while data loads.
class LoadingList extends StatelessWidget {
  final int count;
  const LoadingList({super.key, this.count = 5});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < count; i++)
          Container(
            height: 72,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: AppColors.mist,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
      ],
    );
  }
}

/// Shown when a request fails. The picture and title say what kind of
/// problem it was (offline is not the same as "no route"), and [actionLabel]
/// offers the fix that helps (e.g. "Choose another start"). "Try again" is
/// always there, but only as the main button when retrying can help.
class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final ApiErrorKind kind;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  const ErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.kind = ApiErrorKind.server,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
  });

  (IconData, String) get _look => switch (kind) {
        ApiErrorKind.offline => (Icons.wifi_off_rounded, "Can't reach the server"),
        ApiErrorKind.timeout => (Icons.hourglass_bottom_rounded, 'The server is slow'),
        ApiErrorKind.noRoute => (Icons.alt_route_rounded, 'No route to this place'),
        ApiErrorKind.offCampus => (Icons.location_off_outlined, "You're off the campus paths"),
        ApiErrorKind.notFound => (Icons.wrong_location_outlined, 'Place not found'),
        ApiErrorKind.rateLimited => (Icons.timer_outlined, 'One moment'),
        ApiErrorKind.server => (Icons.error_outline_rounded, 'Something went wrong'),
      };

  /// Retrying helps when the network or server hiccuped, not when the
  /// route simply does not exist.
  bool get _retryFirst =>
      onAction == null ||
      kind == ApiErrorKind.offline ||
      kind == ApiErrorKind.timeout ||
      kind == ApiErrorKind.rateLimited ||
      kind == ApiErrorKind.server;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (icon, title) = _look;
    const big = Size(200, 52);

    final retry = _retryFirst
        ? FilledButton.icon(
            onPressed: onRetry,
            style: FilledButton.styleFrom(minimumSize: big),
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          )
        : TextButton.icon(
            onPressed: onRetry,
            style: TextButton.styleFrom(minimumSize: const Size(160, 48)),
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          );
    final action = onAction == null
        ? null
        : (_retryFirst
            ? OutlinedButton.icon(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(minimumSize: big),
                icon: Icon(actionIcon ?? Icons.arrow_forward),
                label: Text(actionLabel ?? 'Continue'),
              )
            : FilledButton.icon(
                onPressed: onAction,
                style: FilledButton.styleFrom(minimumSize: big),
                icon: Icon(actionIcon ?? Icons.arrow_forward),
                label: Text(actionLabel ?? 'Continue'),
              ));

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        // Read out as soon as it appears.
        child: Semantics(
          liveRegion: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(color: AppColors.mist, shape: BoxShape.circle),
                child: Icon(icon, size: 44, color: AppColors.inkMuted),
              ),
              const SizedBox(height: 18),
              Text(title, style: text.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
              ),
              const SizedBox(height: 24),
              if (_retryFirst) ...[
                retry,
                if (action != null) ...[const SizedBox(height: 10), action],
              ] else ...[
                action!,
                const SizedBox(height: 6),
                retry,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when a search or filter has no results.
class EmptyView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const EmptyView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.inkMuted),
            const SizedBox(height: 16),
            Text(title, style: text.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
            ),
          ],
        ),
      ),
    );
  }
}
