import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// The rounded container around a map or floor plan.
/// With [zoomable] the content can be pinched and dragged.
class MapFrame extends StatelessWidget {
  final double aspectRatio;
  final Widget child;
  final bool zoomable;

  const MapFrame({
    super.key,
    required this.aspectRatio,
    required this.child,
    this.zoomable = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.mapBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.mist),
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: zoomable
            ? InteractiveViewer(minScale: 1, maxScale: 4, child: child)
            : child,
      ),
    );
  }
}
