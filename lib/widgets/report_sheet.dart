import 'package:flutter/material.dart';
import '../models/destination.dart';
import '../models/start_point.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';

/// "Report a problem" sheet. Useful during testing: every report tells you
/// which route or location in the campus data needs fixing.
Future<void> showReportSheet(
  BuildContext context, {
  required Destination destination,
  required StartPoint start,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      // Lift the sheet above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: _ReportSheet(destination: destination, start: start),
    ),
  );
}

class _ReportSheet extends StatefulWidget {
  final Destination destination;
  final StartPoint start;

  const _ReportSheet({required this.destination, required this.start});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  static const List<String> _reasons = [
    'Directions were wrong',
    'A door was locked or closed',
    'The path was blocked',
    'The place is somewhere else',
    'Something else',
  ];

  final _details = TextEditingController();
  int? _reason;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;

    setState(() {
      _sending = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await const ApiService().reportProblem(
        start: widget.start.id,
        destination: widget.destination.id,
        reason: _reasons[reason],
        details: _details.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Thanks. We will check this route.')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Report a problem', style: text.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Route to ${widget.destination.name}, from ${widget.start.name}',
            style: text.bodyMedium?.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _reasons.length; i++)
                _ReasonChip(
                  label: _reasons[i],
                  selected: _reason == i,
                  onTap: () => setState(() => _reason = i),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _details,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Add details (optional)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AppColors.danger)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _reason == null || _sending ? null : _send,
            child: Text(_sending ? 'Sending...' : 'Send report'),
          ),
        ],
      ),
    );
  }
}

class _ReasonChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ReasonChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.ink : Colors.white,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? AppColors.ink : AppColors.mist),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}
