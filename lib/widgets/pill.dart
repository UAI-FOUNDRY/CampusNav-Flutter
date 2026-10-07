import 'package:flutter/material.dart';
import '../theme/destination_style.dart';

/// A small tinted label, e.g. "Academic Building" or "Floor 2".
class Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;

  const Pill({super.key, required this.text, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    final ink = lineInk(color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: ink),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ink),
          ),
        ],
      ),
    );
  }
}
