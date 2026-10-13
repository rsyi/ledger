// Perf #10 (2026-10-12): hidden home tabs mount on first visit (their
// initState loads no longer run at boot), then stay mounted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/ui/widgets/lazy_indexed_stack.dart';

class _Probe extends StatefulWidget {
  const _Probe(this.name, this.log);
  final String name;
  final List<String> log;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.log.add(widget.name);
  }

  @override
  Widget build(BuildContext context) => Text(widget.name);
}

void main() {
  testWidgets('mounts eager + selected tabs only; visited stay mounted',
      (tester) async {
    final log = <String>[];
    Widget stack(int i) => Directionality(
          textDirection: TextDirection.ltr,
          child: LazyIndexedStack(
            index: i,
            eager: const {0, 1},
            children: [
              _Probe('today', log),
              _Probe('log', log),
              _Probe('week', log),
              _Probe('progress', log),
            ],
          ),
        );
    await tester.pumpWidget(stack(0));
    expect(log, ['today', 'log']);
    await tester.pumpWidget(stack(3));
    expect(log, ['today', 'log', 'progress']);
    await tester.pumpWidget(stack(0));
    await tester.pumpWidget(stack(3));
    expect(log, ['today', 'log', 'progress'], reason: 'state kept');
    await tester.pumpWidget(stack(2));
    expect(log.last, 'week');
  });
}
