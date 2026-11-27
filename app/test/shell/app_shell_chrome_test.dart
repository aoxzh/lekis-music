// Tablets are mobile devices: the desktop sidebar + player bar belongs to
// desktop windows only. An Android tablet in landscape (Lenovo TB710FU,
// 1280 x 800 dp) or an unfolded foldable keeps the phone chrome — the
// floating tab bar and the mini player — and only the content adapts to the
// width.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/player/mini_player.dart';
import 'package:lekis/src/features/player/player_bar.dart';
import 'package:lekis/src/features/sources/discovery_providers.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/features/sync/sync_providers.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/app_shell.dart';
import 'package:lekis/src/shell/nav_bar_position.dart';
import 'package:lekis/src/shell/now_playing_context.dart';
import 'package:lekis/src/shell/shell_chrome.dart';
import 'package:lekis/src/shell/sidebar.dart';
import 'package:lekis/src/shell/tab_bar.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _EmptySources extends SourcesNotifier {
  @override
  Future<List<SourceConfigDto>> build() async => [];
}

class _DisabledSync extends SyncController {
  @override
  Future<SyncUiState> build() async => const SyncUiState();
}

class _FixedNavPos extends NavBarPositionNotifier {
  _FixedNavPos(this._initial);
  final NavBarPosition _initial;

  @override
  NavBarPosition build() => _initial;

  @override
  Future<void> set(NavBarPosition value) async => state = value;
}

void _profile(UiProfile profile) {
  UiProfile.debugOverride = profile;
  addTearDown(() => UiProfile.debugOverride = null);
}

Future<void> _pumpShell(
  WidgetTester tester,
  Size size, {
  NavBarPosition navPosition = NavBarPosition.bottom,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        coreEventSourceProvider.overrideWithValue(const Stream.empty()),
        libraryIsEmptyProvider.overrideWith((_) async => true),
        sourcesProvider.overrideWith(_EmptySources.new),
        syncControllerProvider.overrideWith(_DisabledSync.new),
        lanScannerProvider.overrideWithValue(() async => []),
        navBarPositionProvider.overrideWith(() => _FixedNavPos(navPosition)),
      ],
      child: MaterialApp(theme: lekisDarkTheme(), home: const AppShell()),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectMobileChrome({Axis axis = Axis.horizontal}) {
  final bar = find.byType(LekisTabBar);
  expect(bar, findsOneWidget);
  expect((bar.evaluate().single.widget as LekisTabBar).axis, axis);
  expect(find.byType(MiniPlayer), findsOneWidget);
  expect(find.byType(LekisSidebar), findsNothing);
  expect(find.byType(PlayerBar), findsNothing);
  expect(find.byType(NowPlayingContextPanel), findsNothing);
  expect(find.byType(LekisNavRail), findsNothing);
}

void main() {
  group('shellChromeModeFor', () {
    ShellChromeMode mode(
      UiProfile profile,
      Size size, [
      NavBarPosition pos = NavBarPosition.bottom,
    ]) => shellChromeModeFor(size: size, navPosition: pos, profile: profile);

    test('mobile never gets the desktop sidebar', () {
      for (final size in const [
        Size(412, 915), // phone
        Size(690, 829), // Fold5 unfolded, portrait
        Size(904, 820), // Fold5 unfolded, landscape-ish
        Size(800, 1280), // Lenovo TB710FU portrait
        Size(1280, 800), // Lenovo TB710FU landscape
        Size(1600, 1000), // big tablet
      ]) {
        expect(
          mode(UiProfile.mobile, size),
          ShellChromeMode.bottomBar,
          reason: '$size',
        );
        expect(
          mode(UiProfile.mobile, size, NavBarPosition.left),
          ShellChromeMode.sideTabs,
          reason: '$size',
        );
      }
    });

    test('desktop switches to the sidebar from 840 dp', () {
      expect(
        mode(UiProfile.desktop, const Size(800, 800)),
        isNot(ShellChromeMode.sidebar),
      );
      expect(
        mode(UiProfile.desktop, const Size(840, 800)),
        ShellChromeMode.sidebar,
      );
      expect(
        mode(UiProfile.desktop, const Size(1280, 800)),
        ShellChromeMode.sidebar,
      );
    });

    test('short windows use the rail on every profile', () {
      expect(
        mode(UiProfile.mobile, const Size(915, 412)),
        ShellChromeMode.rail,
      );
      expect(
        mode(UiProfile.desktop, const Size(1280, 400)),
        ShellChromeMode.rail,
      );
    });
  });

  testWidgets('Android tablet in landscape (1280x800) gets the bottom bar', (
    tester,
  ) async {
    _profile(UiProfile.mobile);
    await _pumpShell(tester, const Size(1280, 800));
    _expectMobileChrome();

    // Wide screens: a roomier capsule, still centred and compact.
    final capsule = tester.getRect(
      find.byWidgetPredicate(
        (w) =>
            w.key == LekisTabBar.liquidSurfaceKey ||
            w.key == LekisTabBar.flatSurfaceKey,
      ),
    );
    expect(
      capsule.width,
      LekisTabBar.wideSlotWidth * LekisDestination.values.length +
          LekisTabBarTokens.innerInset * 2,
    );
    expect(capsule.center.dx, closeTo(640, 0.5));
  });

  testWidgets('Android tablet in portrait and unfolded Fold5 stay mobile', (
    tester,
  ) async {
    _profile(UiProfile.mobile);
    for (final size in const [Size(800, 1280), Size(904, 1000)]) {
      await _pumpShell(tester, size);
      _expectMobileChrome();
    }
  });

  testWidgets('tablet honours the side nav position setting', (tester) async {
    _profile(UiProfile.mobile);
    await _pumpShell(
      tester,
      const Size(1280, 800),
      navPosition: NavBarPosition.right,
    );
    _expectMobileChrome(axis: Axis.vertical);
  });

  testWidgets('desktop window at 1280x800 keeps the sidebar and player bar', (
    tester,
  ) async {
    _profile(UiProfile.desktop);
    await _pumpShell(tester, const Size(1280, 800));
    expect(find.byType(LekisSidebar), findsOneWidget);
    expect(find.byType(PlayerBar), findsOneWidget);
    expect(find.byType(LekisTabBar), findsNothing);
    expect(find.byType(MiniPlayer), findsNothing);
  });
}
