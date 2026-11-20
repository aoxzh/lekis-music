// The one desktop-vs-mobile switch, and the chrome that follows it.

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:lekis/src/widgets/liquid_glass.dart';
import 'package:material_ui/material_ui.dart';

void _profile(UiProfile profile) {
  UiProfile.debugOverride = profile;
  addTearDown(() => UiProfile.debugOverride = null);
}

Widget _host(Widget child) => MaterialApp(
  theme: lekisDarkTheme(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test('platforms map onto two profiles', () {
    for (final p in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      final profile = UiProfile.forPlatform(p);
      expect(profile.isDesktop, isTrue, reason: '$p');
      expect(profile.supportsGlass, isFalse, reason: '$p');
      expect(profile.offersTabBarStyle, isFalse, reason: '$p');
      expect(profile.prefersSheets, isFalse, reason: '$p');
      expect(profile.supportsHaptics, isFalse, reason: '$p');
      expect(profile.hasSystemVolume, isFalse, reason: '$p');
      expect(profile.visualDensity, VisualDensity.compact, reason: '$p');
    }
    for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
      final profile = UiProfile.forPlatform(p);
      expect(profile.isMobile, isTrue, reason: '$p');
      expect(profile.supportsGlass, isTrue, reason: '$p');
      expect(profile.offersTabBarStyle, isTrue, reason: '$p');
      expect(profile.prefersSheets, isTrue, reason: '$p');
      expect(profile.hasSystemVolume, isTrue, reason: '$p');
    }
    // Only the tray differs between desktops, and only by implementation.
    expect(UiProfile.forPlatform(TargetPlatform.windows).supportsTray, isTrue);
    expect(UiProfile.forPlatform(TargetPlatform.linux).supportsTray, isFalse);
  });

  test('desktop always resolves the tab bar to flat', () {
    _profile(UiProfile.desktop);
    expect(TabBarStyle.liquid.resolved, TabBarStyle.flat);
    UiProfile.debugOverride = UiProfile.mobile;
    expect(TabBarStyle.liquid.resolved, TabBarStyle.liquid);
  });

  testWidgets('desktop glass capsule is flat and opaque (no backdrop blur)', (
    tester,
  ) async {
    _profile(UiProfile.desktop);
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 200,
          height: 56,
          child: LekisGlassCapsule(radius: 28, child: SizedBox.expand()),
        ),
      ),
    );
    expect(find.byType(LiquidGlass), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('mobile glass capsule keeps the liquid glass', (tester) async {
    _profile(UiProfile.mobile);
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 200,
          height: 56,
          child: LekisGlassCapsule(radius: 28, child: SizedBox.expand()),
        ),
      ),
    );
    expect(find.byType(LiquidGlass), findsOneWidget);
  });

  testWidgets('desktop: sheets open as dialogs, even in a narrow window', (
    tester,
  ) async {
    _profile(UiProfile.desktop);
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => showLekisSheet<void>(
                  context,
                  builder: (_) => const Text('sheet body'),
                ),
                child: const Text('sheet'),
              ),
              TextButton(
                onPressed: () => showLekisPanel<void>(
                  context,
                  builder: (_) => const LekisPanel(
                    title: 'panel',
                    body: Text('panel body'),
                  ),
                ),
                child: const Text('panel'),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('sheet'));
    await tester.pumpAndSettle();
    expect(find.text('sheet body'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byKey(const ValueKey('lekis-sheet.dialog')), findsOneWidget);
    Navigator.of(tester.element(find.text('sheet body'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('panel'));
    await tester.pumpAndSettle();
    expect(find.text('panel body'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
  });

  testWidgets('mobile: sheets stay bottom sheets', (tester) async {
    _profile(UiProfile.mobile);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showLekisSheet<void>(
              context,
              builder: (_) => const Text('sheet body'),
            ),
            child: const Text('sheet'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('sheet'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('lekis-sheet.dialog')), findsNothing);
  });

  test('desktop on-media theme is opaque', () {
    _profile(UiProfile.desktop);
    final theme = lekisOnMediaTheme(
      scene: const Color(0xFF202030),
      foreground: const Color(0xFFFFFFFF),
      accent: const Color(0xFF6E5BF0),
      onAccent: const Color(0xFFFFFFFF),
    );
    final surface = theme.extension<LekisSurfaceStyle>()!;
    expect(surface.panel.a, 1);
    expect(surface.blurSigma, 0);
  });
}
