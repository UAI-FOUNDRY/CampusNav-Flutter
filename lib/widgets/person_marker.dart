import 'package:flutter/material.dart';

import '../theme/destination_style.dart';

/// "You are here": your person icon on a coloured disc with a soft halo,
/// like the blue dot in Google Maps. The icon is assets/icons/person.png.
class PersonMarker extends StatelessWidget {
  final Color color;
  final double size;

  const PersonMarker({super.key, required this.color, this.size = 36});

  /// The marker is bigger than the disc because of the halo.
  double get outerSize => size * 1.6;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: outerSize,
      height: outerSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: outerSize,
            height: outerSize,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.22),
              shape: BoxShape.circle,
            ),
          ),
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
              ],
            ),
            child: Center(
              child: Image.asset(
                'assets/icons/person.png',
                width: size * 0.5,
                height: size * 0.5,
                color: readableOnLine(color),
                colorBlendMode: BlendMode.srcIn,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
