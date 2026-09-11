import 'package:flutter/material.dart';

import '../../services/heart_rate_service.dart';

/// Numeric prompt for ledger meta `user_max_hr`. Zone stamps fire at
/// each ladder's hr_pct percent of this value.
Future<void> promptMaxHr(BuildContext context, HeartRateService hr) async {
  final controller =
      TextEditingController(text: hr.maxHr.value?.toString() ?? '');
  final value = await showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Max heart rate'),
      content: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'BPM',
          helperText: 'Zone stamps fire at each ladder\'s % of this '
              '(cardio: 80% / 90%).',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(ctx).pop(int.tryParse(controller.text)),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (value != null && value >= 100 && value <= 230) {
    await hr.setMaxHr(value);
  }
}
