// Floating tab bar: both materials, live style switching, selection
// semantics, reduced-motion fallback and a narrow phone width.

import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/shell/destinations.dart';
import 'package:lekis/src/shell/tab_bar.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _TabHarness extends StatefulWidget {
  const _TabHarness({
    required this.reducedMotion,
    this.style = TabBarStyle.liquid,
  });

  final bool reducedMotion;
  final TabBarStyle style;

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
          style: widget.style,
        ),
      ),
    );
  }
}

class _StyleProviderHarness extends ConsumerWidget {
  const _StyleProviderHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(tabBarStyleProvider);
    return MaterialApp(
      theme: lekisDarkTheme(),
      home: Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: LekisTabBar(
          selected: LekisDestination.home,
          onSelected: (_) {},
          style: style,
        ),
      ),
    );
  }
}

/// Avoids touching the Rust core while still exercising provider-driven
/// live restyling.
class _TestStyleNotifier extends TabBarStyleNotifier {
  @override
  TabBarStyle build() => TabBarStyle.liquid;

  @override
  Future<void> set(TabBarStyle value) async {
    state = value;
  }
}

void main() {
  bool isSelected(WidgetTester tester, LekisDestination destination) =>
      tester
          .getSemantics(find.byKey(LekisTabBar.tabKey(destination)))
          .flagsCollection
          .isSelected ==
      Tristate.isTrue;

  test('style storage defaults to liquid and parses flat', () {
    expect(TabBarStyle.fromStorage(null), TabBarStyle.liquid);
    expect(TabBarStyle.fromStorage('unknown'), TabBarStyle.liquid);
    expect(TabBarStyle.fromStorage('liquid'), TabBarStyle.liquid);
    expect(TabBarStyle.fromStorage('flat'), TabBarStyle.flat);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(tabBarStyleProvider), TabBarStyle.liquid);
  });

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

  testWidgets('liquid blurs; flat stays opaque and hairline-only', (
    tester,
  ) async {
    await tester.pumpWidget(const _TabHarness(reducedMotion: false));

    expect(find.byKey(LekisTabBar.liquidSurfaceKey), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.pumpWidget(
      const _TabHarness(reducedMotion: false, style: TabBarStyle.flat),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(LekisTabBar.flatSurfaceKey), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching the provider restyles the bar live', (tester) async {
    final container = ProviderContainer(
      overrides: [tabBarStyleProvider.overrideWith(_TestStyleNotifier.new)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _StyleProviderHarness(),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);

    await container.read(tabBarStyleProvider.notifier).set(TabBarStyle.flat);
    await tester.pumpAndSettle();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(LekisTabBar.flatSurfaceKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final style in TabBarStyle.values) {
    testWidgets('reduced motion jumps the pill (${style.name})', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(_TabHarness(reducedMotion: true, style: style));

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
  }

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
