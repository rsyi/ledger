import 'package:airledger/ui/widgets/keyboard_inset_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('guardKeyboardInsets (pure)', () {
    const stale = MediaQueryData(
      viewInsets: EdgeInsets.only(bottom: 300),
      viewPadding: EdgeInsets.only(top: 24, bottom: 48),
      padding: EdgeInsets.only(top: 24), // bottom eaten by the inset
    );

    test('zeroes a bottom inset when no keyboard owner is focused', () {
      final out = guardKeyboardInsets(stale, keyboardOwnerFocused: false);
      expect(out.viewInsets.bottom, 0);
      expect(out.padding.bottom, 48); // restored to viewPadding
      expect(out.padding.top, 24);
    });

    test('keeps the inset while a text field is focused', () {
      expect(
        identical(guardKeyboardInsets(stale, keyboardOwnerFocused: true), stale),
        isTrue,
      );
    });

    test('no inset → unchanged', () {
      const mq = MediaQueryData(viewPadding: EdgeInsets.only(bottom: 48));
      expect(
        identical(guardKeyboardInsets(mq, keyboardOwnerFocused: false), mq),
        isTrue,
      );
    });
  });

  group('KeyboardInsetGuard widget', () {
    Future<double Function()> pump(WidgetTester tester, FocusNode node) async {
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      addTearDown(tester.view.resetViewInsets);
      late BuildContext inner;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => KeyboardInsetGuard(child: child!),
        // Read MediaQuery ABOVE the Scaffold — Scaffold strips the bottom
        // inset from its body's MediaQuery.
        home: Builder(builder: (c) {
          inner = c;
          return Scaffold(body: TextField(focusNode: node));
        }),
      ));
      return () => MediaQuery.viewInsetsOf(inner).bottom;
    }

    testWidgets('stale inset dropped with nothing focused', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      final inset = await pump(tester, node);
      expect(inset(), 0);
    });

    testWidgets('inset honored when a TextField has focus, dropped on unfocus',
        (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      final inset = await pump(tester, node);
      node.requestFocus();
      await tester.pump();
      expect(inset(), greaterThan(0));
      node.unfocus();
      await tester.pump();
      expect(inset(), 0);
    });
  });

  test('focusCanOwnKeyboard: null node → false', () {
    expect(focusCanOwnKeyboard(null), isFalse);
  });
}
