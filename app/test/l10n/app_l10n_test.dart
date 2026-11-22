import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/home/home_page.dart';
import 'package:lekis/src/features/settings/settings_categories.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/l10n/app_locale.dart';
import 'package:lekis/src/shell/destinations.dart';
import 'package:lekis/src/shell/sidebar.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('AppLocalePreference.fromStorage roundtrips cleanly', () {
    expect(
      AppLocalePreference.fromStorage('system'),
      AppLocalePreference.system,
    );
    expect(AppLocalePreference.fromStorage('zh'), AppLocalePreference.zh);
    expect(AppLocalePreference.fromStorage('en'), AppLocalePreference.en);
    expect(
      AppLocalePreference.fromStorage('unknown'),
      AppLocalePreference.system,
    );
    expect(AppLocalePreference.zh.locale, const Locale('zh', 'CN'));
    expect(AppLocalePreference.en.locale, const Locale('en', 'US'));
    expect(AppLocalePreference.system.locale, isNull);
  });

  testWidgets('LekisLocale switches navigation, home, and settings live', (
    tester,
  ) async {
    Future<void> pumpLocale(Locale locale) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: lekisDarkTheme(),
          home: LekisLocale(
            locale: locale,
            child: Scaffold(
              body: Row(
                children: [
                  LekisSidebar(
                    selected: LekisDestination.home,
                    onSelected: (_) {},
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        HomeQuickMixStrip(
                          gutter: 16,
                          hasTracks: true,
                          lovedCount: 2,
                          hasMostPlayed: true,
                          genres: const [],
                          onShuffleLibrary: () {},
                          onPlayLoved: () {},
                          onPlayMostPlayed: () {},
                          onPlayGenre: (_) {},
                        ),
                        Builder(
                          builder: (context) => Text(
                            SettingsCategory.appearance.titleOf(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpLocale(const Locale('zh', 'CN'));
    expect(find.text('月兔音乐'), findsOneWidget);
    expect(find.text('LOCAL FIRST'), findsNothing);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('资料库'), findsOneWidget);
    expect(find.text('随机漫游'), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);

    await pumpLocale(const Locale('en', 'US'));
    expect(find.text('Lekis'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Shuffle All'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
  });
}
