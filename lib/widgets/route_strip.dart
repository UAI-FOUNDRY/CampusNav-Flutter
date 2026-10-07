import 'package:flutter/material.dart';
import '../models/route.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import 'pill.dart';

/// The route drawn like a metro line: every step is a station on the line.
///
/// - Floor changes (stairs, lift) are "interchange" stations.
/// - While navigating, pass [currentIndex]: earlier steps turn grey (done) and
///   the current one gets a halo. Use -1 for a plain overview.
class RouteStrip extends StatelessWidget {
  final List<RouteStep> steps;
  final Color lineColor;
  final int currentIndex;

  const RouteStrip({
    super.key,
    required this.steps,
    required this.lineColor,
    this.currentIndex = -1,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          _StepRow(
            step: steps[i],
            isLast: i == steps.length - 1,
            lineColor: lineColor,
            done: currentIndex >= 0 && i < currentIndex,
            current: i == currentIndex,
          ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  final RouteStep step;
  final bool isLast;
  final Color lineColor;
  final bool done;
  final bool current;

  const _StepRow({
    required this.step,
    required this.isLast,
    required this.lineColor,
    required this.done,
    required this.current,
  });

  static const Color _doneColor = Color(0xFFB8C0CE);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accent = done ? _doneColor : lineColor;
    final titleColor = done ? AppColors.inkMuted : AppColors.ink;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 44,
            child: Column(
              children: [
                _marker(accent),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 5,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 3, bottom: isLast ? 0 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        step.title,
                        style: text.titleMedium?.copyWith(color: titleColor),
                      ),
                      if (step.isFloorChange && step.floor != null)
                        Pill(text: floorLabel(step.floor!), color: lineColor),
                    ],
                  ),
                  if (step.instruction.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      step.instruction,
                      style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
                    ),
                  ],
                  if (step.distance != null && step.distance! > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${step.distance!.round()} m',
                      style: text.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: done ? AppColors.inkMuted : lineInk(lineColor),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _marker(Color accent) {
    final isStart = step.type == 'start';
    final isEnd = step.type == 'arrive';
    final interchange = step.isFloorChange;
    final size = (isEnd || interchange) ? 36.0 : 30.0;

    Color fill = Colors.white;
    Color border = accent;
    Color iconColor = done ? accent : lineInk(lineColor);
    IconData icon = iconForStep(step.type);

    if (done) {
      icon = Icons.check;
    } else if (isStart || isEnd) {
      fill = accent;
      iconColor = readableOnLine(lineColor);
    } else if (interchange) {
      border = AppColors.ink;
      iconColor = AppColors.ink;
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 3.5),
        boxShadow: current
            ? [BoxShadow(color: lineColor.withValues(alpha: 0.28), spreadRadius: 6)]
            : null,
      ),
      child: Icon(icon, size: 17, color: iconColor),
    );
  }
}
