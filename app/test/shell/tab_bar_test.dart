// Floating tab bar: selection semantics, reduced-motion fallback and a
// narrow phone width must all behave without layout overflows.

import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/shell/destinations.dart';
import 'package:lekis/src/shell/tab_bar.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _TabHarness extends StatefulWidget {
  const _TabHarness({required this.reducedMotion});

  final bool reducedMotion;

  @override
  State<_TabHarness> createState() => _TabHarnessState();
}

class _TabHarnessState extends State<_TabHarness> {
  LekisDestination _selected = LekisDestination.home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: lekisLightTheme(),
      darkTheme: lekisDarkTheme(),
      themeMode: ThemeMode.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: widget.reducedMotion),
        child: child!,
      ),
      home: Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: LekisTabBar(
          selected: _selected,
          onSelected: (destination) => setState(() => _selected = destination),
        ),
      ),
    );
  }
}

void main() {
  bool isSelected(WidgetTester tester, LekisDestination destination) =>
      tester
          .getSemantics(find.byKey(LekisTabBar.tabKey(destination)))
          .flagsCollection
          .isSelected ==
      Tristate.isTrue;

  testWidgets('exposes five destinations with selected semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(const _TabHarness(reducedMotion: false));

    for (final destination in LekisDestination.values) {
      expect(find.byKey(LekisTabBar.tabKey(destination)), findsOneWidget);
    }
    expect(isSelected(tester, LekisDestination.home), isTrue);
    expect(isSelected(tester, LekisDestination.search), isFalse);

    await tester.tap(find.byKey(LekisTabBar.tabKey(LekisDestination.search)));
    await tester.pump();

    expect(isSelected(tester, LekisDestination.search), isTrue);
    expect(isSelected(tester, LekisDestination.home), isFalse);
    semantics.dispose();
  });

  testWidgets('reduced motion jumps the pill and fades without a spring', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(const _TabHarness(reducedMotion: true));

    final before = tester.getRect(find.byKey(LekisTabBar.selectionKey));
    await tester.tap(find.byKey(LekisTabBar.tabKey(LekisDestination.search)));
    await tester.pump();

    final after = tester.getRect(find.byKey(LekisTabBar.selectionKey));
    expect(after.left, greaterThan(before.left));
    expect(isSelected(tester, LekisDestination.search), isTrue);

    await tester.pump(LekisMotion.fast);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('fits a 320 dp phone and sends a selection haptic', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(const _TabHarness(reducedMotion: false));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(LekisTabBar.tabKey(LekisDestination.library)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      calls.any(
        (call) =>
            call.method == 'HapticFeedback.vibrate' &&
            call.arguments == 'HapticFeedbackType.selectionClick',
      ),
      isTrue,
    );
  });
}
