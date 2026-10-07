import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';

/// A row of floor pills: Ground, Floor 1, Floor 2 ...
class FloorSelector extends StatelessWidget {
  final List<int> floors;
  final int selected;
  final ValueChanged<int> onChanged;
  final Color color;

  const FloorSelector({
    super.key,
    required this.floors,
    required this.selected,
    required this.onChanged,
    this.color = AppColors.academic,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: floors.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final floor = floors[i];
          final isSelected = floor == selected;
          return Material(
            color: isSelected ? color : Colors.white,
            shape: StadiumBorder(
              side: BorderSide(color: isSelected ? color : AppColors.mist),
            ),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => onChanged(floor),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Center(
                  child: Text(
                    floor == 0 ? 'Ground' : 'Floor $floor',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? readableOnLine(color) : AppColors.ink,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
