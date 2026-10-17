import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'zoomable_view.dart';

/// The rounded container around a map or floor plan.
///
/// With [zoomable] the content can be pinched, dragged and double-tapped.
/// Pass [builder] instead of [child] to get the current zoom, so line widths
/// and markers can stay the same size on screen (see [zoomCompensation]).
/// [focus] opens the view zoomed onto that part of the content (fractions).
class MapFrame extends StatelessWidget {
  final double aspectRatio;
  final Widget? child;
  final Widget Function(BuildContext context, double zoom)? builder;
  final bool zoomable;
  final Rect? focus;
  final double maxScale;

  const MapFrame({
    super.key,
    required this.aspectRatio,
    this.child,
    this.builder,
    this.zoomable = false,
    this.focus,
    this.maxScale = 6,
  }) : assert(child != null || builder != null, 'Give MapFrame a child or a builder');

  Widget _content(BuildContext context, double zoom) =>
      builder != null ? builder!(context, zoom) : child!;

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
            ? ZoomableView(
                builder: (context, zoom, rotation) => _content(context, zoom),
                focus: focus,
                maxScale: maxScale,
                // Cards in a scrolling page stay north-up; full-screen maps turn.
                rotate: false,
              )
            : _content(context, 1),
      ),
    );
  }
}
