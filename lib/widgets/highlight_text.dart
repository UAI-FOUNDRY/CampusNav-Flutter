import 'package:flutter/material.dart';

/// Text with every match of [query] shown in bold on a soft yellow background.
class HighlightText extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle? style;

  const HighlightText({
    super.key,
    required this.text,
    required this.query,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    if (q.isEmpty) return Text(text, style: style);

    final lowerText = text.toLowerCase();
    final lowerQuery = q.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;

    while (true) {
      final i = lowerText.indexOf(lowerQuery, start);
      if (i < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (i > start) spans.add(TextSpan(text: text.substring(start, i)));
      spans.add(TextSpan(
        text: text.substring(i, i + q.length),
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          backgroundColor: Color(0x40F2A900),
        ),
      ));
      start = i + q.length;
    }

    return Text.rich(TextSpan(style: style, children: spans));
  }
}
