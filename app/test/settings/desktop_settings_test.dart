// Desktop settings: Windows-11-style list + detail, no mobile-only options.
// Mobile keeps its own layout and options (checked side by side here).

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_controller.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/enrich/enrich_providers.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage_settings.dart';
import 'package:lekis/src/features/plugins/plugins_page.dart';
import 'package:lekis/src/features/plugins/strings.dart';
import 'package:lekis/src/features/settings/desktop_settings_view.dart';
import 'package:lekis/src/features/settings/settings_page.dart';
import 'package:lekis/src/features/settings/settings_search.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/settings/strings.dart';
import 'package:lekis/src/features/settings/tab_bar_style_picker.dart';
import 'package:lekis/src/features/settings/theme_preference.dart';
import 'package:lekis/src/features/settings/usb_bit_perfect_providers.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/nav_bar_position.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakeSources extends SourcesNotifier {
  @override
  Future<List<SourceConfigDto>> build() async => const [
    SourceConfigDto(
      kind: SourceKindDto.local,
      name: 'Music',
      addresses: ['/music'],
      rootPath: '',
      options: {},
      enabled: true,
    ),
  ];
}

class _FakePending extends EnrichPendingCountNotifier {
  @override
  int? build() => 0;
}

// Built after the profile is set: the theme reads it too.
Widget _app({bool usb = false, LyricsStyle style = LyricsStyle.classic}) =>
    ProviderScope(
      overrides: [
        usbBitPerfectSupportedProvider.overrideWithValue(usb),
        desktopLyricsSupportedProvider.overrideWithValue(false),
        lyricsStyleProvider.overrideWithValue(style),
        sourcesProvider.overrideWith(_FakeSources.new),
        enrichPendingCountProvider.overrideWith(_FakePending.new),
        downloadsSummaryProvider.overrideWithValue((
          readyCount: 0,
          totalBytes: 0,
          activeCount: 0,
        )),
        aboutInfoProvider.overrideWithValue(
          const AboutInfo(coreVersion: '9.9.9', deviceId: 'dev-1'),
        ),
      ],
      child: MaterialApp(
        theme: lekisDarkTheme(),
        home: const Material(child: SettingsPage()),
      ),
    );

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void _profile(UiProfile profile) {
  UiProfile.debugOverride = profile;
  addTearDown(() => UiProfile.debugOverride = null);
}

Finder _category(String name) =>
    find.byKey(ValueKey('settings-category-$name'));

void main() {
  group('desktop profile', () {
    testWidgets('search jumps to a specific lyric row in the detail pane', (
      tester,
    ) async {
      _profile(UiProfile.desktop);
      _size(tester, const Size(1280, 510));
      await tester.pumpWidget(_app());
      final field = find.byKey(DesktopSettingsView.searchKey);
      await tester.enterText(field, 'translation');
      await tester.pump();
      final result = find.widgetWithText(
        SettingsSearchRow,
        SettingsStrings.lyricsTranslation,
      );
      expect(
        find.descendant(
          of: result,
          matching: find.text(
            '${SettingsStrings.appearance} › ${SettingsStrings.lyrics}',
          ),
        ),
        findsOneWidget,
      );
      expect(result, findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('lyrics.translation'));
      final position = Scrollable.of(tester.element(row)).position;
      expect(position.pixels, greaterThan(0));
      expect(row.hitTestable(), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      position.jumpTo(0);
      await tester.pump();
      expect(row.hitTestable(), findsNothing);
      await tester.tap(result);
      await tester.pumpAndSettle();
      expect(row.hitTestable(), findsOneWidget);
    });
    testWidgets('1280x820: category list on the left, detail on the right', (
      tester,
    ) async {
      _profile(UiProfile.desktop);
      _size(tester, const Size(1280, 820));
      await tester.pumpWidget(_app());
      await tester.pump();

      expect(find.byType(DesktopSettingsView), findsOneWidget);
      expect(find.byKey(DesktopSettingsView.searchKey), findsOneWidget);
      // Every group and category is in the left list.
      for (final c in SettingsCategory.values) {
        expect(_category(c.name), findsOneWidget);
      }
      // 音源 lives in the sidebar on desktop; not repeated in Settings.
      expect(find.byKey(const ValueKey('settings-sources')), findsNothing);

      // Playback is open by default, to the right of the list.
      final nav = tester.getRect(_category('playback'));
      final detail = tester.getRect(find.text(SettingsStrings.gapless));
      expect(detail.left, greaterThan(nav.right));
      expect(nav.right, lessThanOrEqualTo(desktopSettingsNavWidth + 1));

      // Desktop controls: dropdowns and labelled toggles, no chips /
      // segmented buttons / bottom-sheet pickers.
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byWidgetPredicate((w) => w is SegmentedButton), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is SettingsComboBox),
        findsWidgets,
      );
      expect(find.text(SettingsWidgetStrings.on), findsWidgets);

      // Selecting a category swaps the detail in place (no pushed page).
      await tester.tap(_category('about'));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('9.9.9'), findsOneWidget);
      expect(
        tester.getRect(find.text(SettingsStrings.coreVersion)).left,
        greaterThan(tester.getRect(_category('about')).right),
      );
    });

    testWidgets(
      'appearance hides the glass tab bar style; theme is a dropdown',
      (tester) async {
        _profile(UiProfile.desktop);
        _size(tester, const Size(1280, 820));
        await tester.pumpWidget(_app());
        await tester.pump();

        await tester.tap(_category('appearance'));
        await tester.pumpAndSettle();

        expect(find.text(SettingsStrings.tabBarStyle), findsNothing);
        expect(find.byType(TabBarStylePicker), findsNothing);
        expect(find.text(SettingsStrings.tabBarLiquid), findsNothing);
        expect(find.byKey(const ValueKey('settings-theme')), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is SegmentedButton),
          findsNothing,
        );
        // The category hint no longer promises a tab bar option.
        expect(
          SettingsCategory.appearance.hint,
          SettingsStrings.appearanceHintDesktop,
        );

        // Clicking the row opens a menu with every theme.
        await tester.tap(find.text(SettingsStrings.theme));
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('settings-choice-${SettingsStrings.themeOled}')),
          findsOneWidget,
        );
      },
    );

    testWidgets('desktop type scale; page title is not repeated as a section', (
      tester,
    ) async {
      _profile(UiProfile.desktop);
      _size(tester, const Size(1280, 820));
      await tester.pumpWidget(_app());
      await tester.pump();
      await tester.tap(_category('appearance'));
      await tester.pumpAndSettle();

      // Once in the list, once as the page title — no "外观" section label.
      expect(find.text(SettingsStrings.appearance), findsNWidgets(2));

      double sizeOf(Finder f) =>
          tester.widget<Text>(f).style?.fontSize ??
          DefaultTextStyle.of(tester.element(f)).style.fontSize!;
      final titles = find.text(SettingsStrings.appearance);
      final sizes = [sizeOf(titles.at(0)), sizeOf(titles.at(1))]..sort();
      expect(sizes, [
        LekisDesktopType.item.size,
        LekisDesktopType.pageTitle.size,
      ]);
      expect(
        sizeOf(find.text(SettingsStrings.title)),
        LekisDesktopType.paneTitle.size,
      );
      // Group labels share the 12 px header level.
      expect(
        sizeOf(find.text(SettingsCategoryGroup.general.title)),
        LekisDesktopType.sectionHeader.size,
      );
    });

    testWidgets('Ctrl+F focuses search and filters the list', (tester) async {
      _profile(UiProfile.desktop);
      _size(tester, const Size(1280, 820));
      await tester.pumpWidget(_app());
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      final field = tester.widget<TextField>(
        find.byKey(DesktopSettingsView.searchKey),
      );
      expect(field.focusNode!.hasFocus, isTrue);

      // A row title inside a category finds the category.
      await tester.enterText(
        find.byKey(DesktopSettingsView.searchKey),
        SettingsStrings.diagnosticLogs,
      );
      await tester.pump();
      expect(_category('advanced'), findsOneWidget);
      expect(_category('playback'), findsNothing);
      expect(_category('appearance'), findsNothing);

      // Enter opens the first match.
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text(SettingsStrings.diagnosticLogs), findsWidgets);

      await tester.enterText(
        find.byKey(DesktopSettingsView.searchKey),
        'zzzz-nothing',
      );
      await tester.pump();
      expect(find.text(SettingsStrings.searchEmpty), findsOneWidget);
    });

    testWidgets('narrow desktop window: pushed pages, still no glass options', (
      tester,
    ) async {
      _profile(UiProfile.desktop);
      _size(tester, const Size(560, 900));
      await tester.pumpWidget(_app());
      await tester.pump();

      expect(find.byType(DesktopSettingsView), findsNothing);
      await tester.tap(_category('appearance'));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text(SettingsStrings.tabBarStyle), findsNothing);
      expect(find.byKey(const ValueKey('settings-theme')), findsOneWidget);
    });
  });

  group('mobile profile', () {
    testWidgets(
      'phone opens the exact setting and returns to its English search results',
      (tester) async {
        _profile(UiProfile.mobile);
        _size(tester, const Size(412, 680));
        await tester.pumpWidget(
          LekisLocale(locale: const Locale('en'), child: _app()),
        );
        final field = find.byKey(const ValueKey('settings-mobile-search'));
        await tester.enterText(field, '歌词字号');
        await tester.pump();
        final result = find.widgetWithText(
          SettingsSearchRow,
          'Lyrics text size',
        );
        await tester.tap(result);
        await tester.pumpAndSettle();
        final row = find.byKey(const ValueKey('settings-lyrics-font-size'));
        expect(row.hitTestable(), findsOneWidget);
        expect(
          Scrollable.of(tester.element(row)).position.pixels,
          greaterThan(0),
        );
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(result.hitTestable(), findsOneWidget);
        await tester.enterText(field, 'plugins install');
        await tester.pump();
        await tester.tap(
          find.widgetWithText(SettingsSearchRow, PluginStrings.install),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PluginsPage), findsOneWidget);
        await tester.tap(find.byTooltip(PluginStrings.install));
        await tester.pumpAndSettle();
        expect(find.text(PluginStrings.installFolder), findsOneWidget);
      },
    );

    testWidgets('search follows USB support and the selected lyric style', (
      tester,
    ) async {
      _profile(UiProfile.mobile);
      _size(tester, const Size(412, 680));
      await tester.pumpWidget(_app(usb: true, style: LyricsStyle.flow));
      final field = find.byKey(const ValueKey('settings-mobile-search'));
      await tester.enterText(field, 'audio output');
      await tester.pump();
      expect(
        find.widgetWithText(SettingsSearchRow, SettingsStrings.usbBitPerfect),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(SettingsSearchRow, SettingsStrings.outputMode),
        findsNothing,
      );
      await tester.tap(
        find.widgetWithText(SettingsSearchRow, SettingsStrings.usbBitPerfect),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings.usb-bit-perfect')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.enterText(field, 'lyrics');
      await tester.pump();
      expect(
        find.widgetWithText(SettingsSearchRow, SettingsStrings.lyricsSparks),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(SettingsSearchRow, SettingsStrings.lyricsRuby),
        findsNothing,
      );
      expect(find.widgetWithText(SettingsSearchRow, '桌面歌词'), findsNothing);
    });
    testWidgets('phone keeps the tab bar style and segmented theme picker', (
      tester,
    ) async {
      _profile(UiProfile.mobile);
      _size(tester, const Size(400, 1400));
      await tester.pumpWidget(_app());
      await tester.pump();

      await tester.tap(_category('appearance'));
      await tester.pumpAndSettle();

      expect(find.text(SettingsStrings.tabBarStyle), findsOneWidget);
      expect(find.byType(TabBarStylePicker), findsOneWidget);
      expect(find.text(SettingsStrings.navBarPosition), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is SegmentedButton<ThemePreference>),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate((w) => w is SegmentedButton<NavBarPosition>),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('settings-theme')), findsNothing);
      expect(SettingsCategory.appearance.hint, SettingsStrings.appearanceHint);
    });

    testWidgets('wide tablet keeps the two-pane list, not the desktop view', (
      tester,
    ) async {
      _profile(UiProfile.mobile);
      _size(tester, const Size(1280, 820));
      await tester.pumpWidget(_app());
      await tester.pump();

      expect(find.byType(DesktopSettingsView), findsNothing);
      expect(find.byType(ChoiceChip), findsWidgets);
      expect(find.byKey(DesktopSettingsView.searchKey), findsNothing);
    });
  });
}
