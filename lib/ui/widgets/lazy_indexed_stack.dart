/// An [IndexedStack] that MOUNTS each child only once it has been
/// selected (perf #10, 2026-10-12). Hidden tabs used to build — and fire
/// every load in their initState — at boot. Once visited, a child stays
/// mounted (state, scroll and in-flight futures preserved exactly like
/// IndexedStack). Indices in [eager] mount immediately.
library;

import 'package:flutter/widgets.dart';

class LazyIndexedStack extends StatefulWidget {
  const LazyIndexedStack({
    super.key,
    required this.index,
    required this.children,
    this.eager = const {},
    this.sizing = StackFit.loose,
  });

  final int index;
  final List<Widget> children;
  final Set<int> eager;
  final StackFit sizing;

  @override
  State<LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<LazyIndexedStack> {
  final Set<int> _mounted = {};

  @override
  Widget build(BuildContext context) {
    _mounted
      ..addAll(widget.eager)
      ..add(widget.index);
    return IndexedStack(
      index: widget.index,
      sizing: widget.sizing,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          _mounted.contains(i) ? widget.children[i] : const SizedBox.shrink(),
      ],
    );
  }
}
