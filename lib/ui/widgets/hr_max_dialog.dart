import 'package:flutter/material.dart';

import '../../services/heart_rate_service.dart';

/// Numeric prompt for ledger meta `user_max_hr`. Zone stamps fire at
/// each ladder's hr_pct percent of this value.
Future<void> promptMaxHr(BuildContext context, HeartRateService hr) async {
  final value = await showDialog<int>(
    context: context,
    builder: (_) => _MaxHrDialog(initial: hr.maxHr.value),
  );
  if (value != null) {
    await hr.setMaxHr(value);
  }
}

class _MaxHrDialog extends StatefulWidget {
  const _MaxHrDialog({this.initial});

  final int? initial;

  @override
  State<_MaxHrDialog> createState() => _MaxHrDialogState();
}

class _MaxHrDialogState extends State<_MaxHrDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: widget.initial?.toString() ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = int.tryParse(_controller.text);
    if (value == null || value < 100 || value > 230) {
      setState(() => _errorText = 'Enter 100–230 BPM');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Max heart rate'),
      content: TextField(
        controller: _controller,
        keyboardType: TextInputType.number,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'BPM',
          helperText: 'Zone stamps fire at each ladder\'s % of this '
              '(cardio: 80% / 90%).',
          errorText: _errorText,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
