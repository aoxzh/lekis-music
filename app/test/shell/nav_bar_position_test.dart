import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/widgets/shelf.dart';
import 'package:lekis/src/features/settings/settings_categories.dart';
import 'package:lekis/src/features/settings/strings.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/shell/nav_bar_position.dart';
import 'package:lekis/src/shell/shell_chrome.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FixedNavPosNotifier extends NavBarPositionNotifier {
  _FixedNavPosNotifier(this._initial);
  final NavBarPosition _initial;

  @override
  NavBarPosition build() => _initial;

  @override
  Future<void> set(NavBarPosition value) async {
    state = value;
  }
}

void main() {
  test('NavBarPosition.fromStorage defaults to bottom on unknown/null', () {
    expect(NavBarPosition.fromStorage(null), NavBarPosition.bottom);
    expect(NavBarPosition.fromStorage(''), NavBarPosition.bottom);
    expect(NavBarPosition.fromStorage('unknown'), NavBarPosition.bottom);
    expect(NavBarPosition.fromStorage('bottom'), NavBarPosition.bottom);
    expect(NavBarPosition.fromStorage('left'), NavBarPosition.left);
    expect(NavBarPosition.fromStorage('right'), NavBarPosition.right);
  });

  testWidgets('ShellChrome exposes floating right nav flag accurately', (
    tester,
  ) async {
    bool? rightFlag;
    NavBarPosition? pos;

    Widget probe(ShellChromeMode mode, NavBarPosition navPosition) =>
        ShellChrome(
          mode: mode,
          navPosition: navPosition,
          child: Builder(
            builder: (context) {
              rightFlag = ShellChrome.hasFloatingRightNavOf(context);
              pos = ShellChrome.navPositionOf(context);
              return const SizedBox.shrink();
            },
          ),
        );

    await tester.pumpWidget(
      probe(ShellChromeMode.sideTabs, NavBarPosition.right),
    );
    expect(rightFlag, isTrue);
    expect(pos, NavBarPosition.right);

    await tester.pumpWidget(
      probe(ShellChromeMode.sideTabs, NavBarPosition.left),
    );
    expect(rightFlag, isFalse);
    expect(pos, NavBarPosition.left);

    await tester.pumpWidget(
      probe(ShellChromeMode.bottomBar, NavBarPosition.bottom),
    );
    expect(rightFlag, isFalse);
    expect(pos, NavBarPosition.bottom);
  });

  testWidgets('Appearance settings offers nav bar position on mobile only', (
    tester,
  ) async {
    UiProfile.debugOverride = UiProfile.mobile;
    addTearDown(() => UiProfile.debugOverride = null);

    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          navBarPositionProvider.overrideWith(
            () => _FixedNavPosNotifier(NavBarPosition.bottom),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              theme: lekisDarkTheme(),
              home: Scaffold(
                body: ListView(children: SettingsCategory.appearance.sections),
              ),
            );
          },
        ),
      ),
    );

    expect(find.text(SettingsStrings.navBarPosition), findsOneWidget);
    expect(find.text(SettingsStrings.navBarBottom), findsOneWidget);
    expect(find.text(SettingsStrings.navBarLeft), findsOneWidget);
    expect(find.text(SettingsStrings.navBarRight), findsOneWidget);

    await tester.tap(find.text(SettingsStrings.navBarLeft));
    await tester.pumpAndSettle();
    expect(container.read(navBarPositionProvider), NavBarPosition.left);

    await tester.tap(find.text(SettingsStrings.navBarRight));
    await tester.pumpAndSettle();
    expect(container.read(navBarPositionProvider), NavBarPosition.right);

    // 桌面端不展示移动端悬浮导航栏位置选项。
    UiProfile.debugOverride = UiProfile.desktop;
    await tester.pumpWidget(
      ProviderScope(
        key: const ValueKey('desktop-scope'),
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(
            body: ListView(children: SettingsCategory.appearance.sections),
          ),
        ),
      ),
    );
    expect(find.text(SettingsStrings.navBarPosition), findsNothing);
  });

  testWidgets(
    'ArtworkShelf keeps trailing action inside asymmetric safe area while list bleeds full-width',
    (tester) async {
      tester.view.physicalSize = const Size(690, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: lekisDarkTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(690, 820),
              padding: EdgeInsets.only(right: 80),
            ),
            child: Scaffold(
              body: ArtworkShelf(
                title: '最近播放',
                trailing: TextButton(
                  onPressed: () {},
                  child: const Text('查看全部'),
                ),
                itemCount: 8,
                itemBuilder: (_, i) => ColoredBox(
                  color: const Color(0xFF443366),
                  child: Center(child: Text('Item $i')),
                ),
              ),
            ),
          ),
        ),
      );

      final listRect = tester.getRect(find.byType(ListView));
      final trailingRect = tester.getRect(find.text('查看全部'));
      // 横滑列表占满整屏 690 dp（可从右侧悬浮玻璃下方穿过）
      expect(listRect.width, 690);
      // 静态操作按钮（查看全部）严格留在 690 - 80 = 610 dp 安全区内，不被右侧导航栏遮挡
      expect(trailingRect.right, lessThanOrEqualTo(610));
    },
  );
}
