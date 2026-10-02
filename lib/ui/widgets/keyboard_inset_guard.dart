import 'package:flutter/widgets.dart';

/// Drops a STALE keyboard inset app-wide.
///
/// Bug: after switching back from another app (often one with its keyboard
/// up), or returning right after logging from a form whose keyboard was
/// open, Android's IME-animation insets path can leave Flutter holding the
/// last keyboard height in `MediaQuery.viewInsets.bottom` with no keyboard
/// on screen. Every `resizeToAvoidBottomInset` Scaffold then stays shrunk —
/// the screen looks "cut off" until some later inset update. The primary
/// fix is native (MainActivity re-pushes the real window insets on focus
/// regain); this is the belt-and-braces Dart side.
///
/// Rule: a non-zero bottom inset is honored only while something that can
/// own the keyboard has focus — an [EditableText] or a platform view
/// (e.g. the OAuth WebView). Otherwise the bottom inset is zeroed and the
/// bottom padding restored to `viewPadding` (Flutter derives padding as
/// viewPadding minus insets, so it was eaten by the stale inset too).
class KeyboardInsetGuard extends StatefulWidget {
  const KeyboardInsetGuard({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardInsetGuard> createState() => _KeyboardInsetGuardState();
}

class _KeyboardInsetGuardState extends State<KeyboardInsetGuard> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final fixed = guardKeyboardInsets(
      mq,
      keyboardOwnerFocused:
          focusCanOwnKeyboard(FocusManager.instance.primaryFocus),
    );
    if (identical(fixed, mq)) return widget.child;
    return MediaQuery(data: fixed, child: widget.child);
  }
}

/// Pure core: returns [mq] unchanged unless it carries a bottom inset with
/// no keyboard owner focused, in which case the inset is zeroed.
MediaQueryData guardKeyboardInsets(
  MediaQueryData mq, {
  required bool keyboardOwnerFocused,
}) {
  if (mq.viewInsets.bottom <= 0 || keyboardOwnerFocused) return mq;
  return mq.copyWith(
    viewInsets: mq.viewInsets.copyWith(bottom: 0),
    padding: mq.padding.copyWith(
      bottom: mq.padding.bottom > mq.viewPadding.bottom
          ? mq.padding.bottom
          : mq.viewPadding.bottom,
    ),
  );
}

/// True when the focused node belongs to a text input or a platform view.
bool focusCanOwnKeyboard(FocusNode? node) {
  final ctx = node?.context;
  if (ctx == null) return false;
  final w = ctx.widget;
  if (w is EditableText || w is PlatformViewLink || w is AndroidView) {
    return true;
  }
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null ||
      ctx.findAncestorWidgetOfExactType<PlatformViewLink>() != null ||
      ctx.findAncestorWidgetOfExactType<AndroidView>() != null;
}
