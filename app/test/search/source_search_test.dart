import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/plugins/plugins_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/search/search_page.dart';
import 'package:lekis/src/features/search/search_providers.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

PluginInfoDto source({
  bool enabled = true,
  String name = 'Demo source',
  String id = 'dev.lekis.test.music',
}) => PluginInfoDto(
  id: id,
  name: name,
  compatibility: 'mygo',
  version: '1.0.0',
  apiVersion: '1.0',
  runtime: 'js',
  kinds: const ['source'],
  entry: 'index.js',
  enabled: enabled,
  nativeAndroidGranted: false,
  directory: 'dev.lekis.test.music',
  permissions: const PluginPermissionsDto(
    network: [],
    process: [],
    requestHeaderHosts: [],
    webSignIn: false,
    nativeAndroid: false,
    storageKb: 1024,
  ),
  settings: const [],
);

class IdlePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState();
}

class Sources extends PluginListNotifier {
  Sources(this.values);
  final List<PluginInfoDto> values;
  @override
  Future<List<PluginInfoDto>> build() async => values;
}

final results = SearchResultsDto(
  tracks: [
    TrackRowDto(
      id: 1,
      title: 'Evening light',
      artistLine: 'Demo artist',
      durationMs: BigInt.from(208000),
      loved: false,
      isLocal: false,
    ),
  ],
  albums: [],
  artists: [],
);

void main() {
  final boundaryKey = GlobalKey();
  Finder sourcePicker() =>
      find.byKey(const ValueKey('search-source-picker')).evaluate().isNotEmpty
      ? find.byKey(const ValueKey('search-source-picker'))
      : find.descendant(
          of: find.byType(SettingsComboBox<String>),
          matching: find.byType(OutlinedButton),
        );
  setUpAll(() async {
    final iconPath = Platform.environment['LEKIS_UI_ICONS'];
    if (iconPath != null) {
      final bytes = ByteData.sublistView(await File(iconPath).readAsBytes());
      await (FontLoader('MaterialIcons')..addFont(Future.value(bytes))).load();
    }
    final fontPath = Platform.environment['LEKIS_UI_FONT'];
    if (fontPath != null) {
      final bytes = ByteData.sublistView(await File(fontPath).readAsBytes());
      for (final family in [
        'Roboto',
        '.AppleSystemUIFont',
        'PingFang SC',
        'Ahem',
      ]) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
  });
  tearDown(() => UiProfile.debugOverride = null);

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    String? selected,
    List<PluginInfoDto>? plugins,
    bool dark = false,
    bool active = true,
    String initialQuery = 'evening',
    String? fixedSource,
    Locale locale = const Locale('en'),
    Future<SearchResultsDto?> Function(Ref ref)? loadResults,
  }) async {
    final container = ProviderContainer.test(
      overrides: [
        playbackProvider.overrideWith(IdlePlayback.new),
        trackArtworkProvider.overrideWith((ref, id) async => null),
        pluginListProvider.overrideWith(() => Sources(plugins ?? [source()])),
        searchSourceProvider.overrideWith(() => SimpleValue<String?>(selected)),
        searchQueryProvider.overrideWith(
          () => SimpleValue<String>(initialQuery),
        ),
        librarySourceSearchProvider.overrideWith(
          (ref, request) async => results,
        ),
        searchResultsProvider.overrideWith(
          loadResults ?? (ref) async => results,
        ),
      ],
    );
    if (Platform.environment['LEKIS_UI_FONT'] != null) {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
    }
    var theme = dark ? lekisDarkTheme() : lekisLightTheme();
    if (Platform.environment['LEKIS_UI_FONT'] != null) {
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
        primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'Roboto'),
      );
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: LekisLocale(
          locale: locale,
          child: MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: boundaryKey,
              child: TickerMode(
                enabled: active,
                child: SearchPage(pluginId: fixedSource),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> capture(WidgetTester tester, String? output, String name) async {
    if (output == null) return;
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory(output).create(recursive: true);
        await File('$output/$name.png').writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
  }

  for (final (name, size, chinese) in [
    ('narrow', const Size(320, 640), true),
    ('wide', const Size(1000, 620), false),
  ]) {
    testWidgets('search tools, empty state and history at $name width', (
      tester,
    ) async {
      UiProfile.debugOverride = chinese ? UiProfile.mobile : UiProfile.desktop;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final container = await mount(
        tester,
        initialQuery: '',
        locale: Locale(chinese ? 'zh' : 'en'),
        dark: chinese,
      );
      final catalogue = find.byKey(const ValueKey('spotify-catalog-entry'));
      final scope = find.text(chinese ? '搜索范围' : 'Search in');
      final field = find.byType(SearchBar);
      final picker = tester.getRect(sourcePicker());
      final link = tester.getRect(catalogue);
      expect(tester.getRect(scope).center.dy, closeTo(picker.center.dy, 1));
      if (chinese) {
        expect(link.top, greaterThanOrEqualTo(picker.bottom));
      } else {
        expect(link.center.dy, closeTo(picker.center.dy, 1));
      }
      expect(tester.getSize(field).height, lessThanOrEqualTo(50));
      final empty = chinese ? '搜索你的资料库' : 'Search Your Library';
      expect(find.text(empty), findsOneWidget);
      final output = Platform.environment['LEKIS_SEARCH_REFRESH_CAPTURE_DIR'];
      await capture(tester, output, '$name-empty');
      final queries = chinese
          ? ['落日飞车', '椎名林檎', '夜航星']
          : ['In Rainbows', 'Little Simz', 'Blue Train'];
      for (final query in queries) {
        await tester.enterText(field, query);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip(chinese ? '清除' : 'Clear'));
      await tester.pumpAndSettle();
      expect(find.text(empty), findsNothing);
      final recent = find.byType(ListTile);
      expect(
        tester
            .widgetList<ListTile>(recent)
            .map((row) => (row.title! as Text).data),
        queries.reversed,
      );
      await capture(tester, output, '$name-history');
      if (!chinese) {
        final lastRow = find.byKey(ValueKey(queries.last));
        for (var press = 0; press < 12; press++) {
          if (Focus.of(
            tester.element(
              find.descendant(of: lastRow, matching: find.text(queries.last)),
            ),
          ).hasPrimaryFocus) {
            break;
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(find.text(queries.last));
      }
      await tester.pumpAndSettle();
      expect(container.read(searchQueryProvider), queries.last);
      await tester.tap(field);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(container.read(searchQueryProvider), isEmpty);
      await tester.tap(
        find.byTooltip(
          chinese ? '移除“${queries.last}”' : 'Remove "${queries.last}"',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(queries.last), findsNothing);
      await tester.tap(find.text(chinese ? '清空' : 'Clear all'));
      await tester.pumpAndSettle();
      expect(find.text(empty), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'fixed plugin reuses the search field and keeps scope and query independent',
    (tester) async {
      UiProfile.debugOverride = UiProfile.desktop;
      final container = await mount(tester, fixedSource: source().id);
      expect(find.text('Demo source'), findsOneWidget);
      expect(find.text('Browse source'), findsOneWidget);
      expect(find.byKey(const ValueKey('spotify-catalog-entry')), findsNothing);
      expect(find.byType(SettingsComboBox<String>), findsNothing);
      await tester.enterText(find.byType(SearchBar), 'river');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(container.read(searchSourceProvider), isNull);
      expect(container.read(searchQueryProvider), 'evening');
      expect(find.text('Evening light'), findsOneWidget);
    },
  );

  Future<void> pressFind(
    WidgetTester tester,
    LogicalKeyboardKey modifier,
  ) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  testWidgets(
    'fixed missing source cannot be mistaken for another installed plugin',
    (tester) async {
      await mount(tester, fixedSource: 'missing.plugin');
      expect(find.text('Source unavailable'), findsOneWidget);
      expect(find.text('Demo source'), findsNothing);
      expect(find.text('Browse source'), findsNothing);
    },
  );

  testWidgets('Escape leaves an active IME composition intact', (tester) async {
    UiProfile.debugOverride = UiProfile.desktop;
    final container = await mount(tester);
    await tester.tap(find.byType(SearchBar));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'lin',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(container.read(searchQueryProvider), 'lin');
  });

  for (final modifier in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.metaLeft,
  ]) {
    testWidgets('${modifier.keyLabel}+F refocuses and selects the query', (
      tester,
    ) async {
      UiProfile.debugOverride = UiProfile.desktop;
      final container = await mount(tester);
      final field = tester.widget<EditableText>(find.byType(EditableText));
      field.focusNode.unfocus();
      await tester.pump();
      expect(field.focusNode.hasFocus, isFalse);

      await pressFind(tester, modifier);
      expect(field.focusNode.hasFocus, isTrue);
      expect(
        field.controller.selection.textInside(field.controller.text),
        'evening',
      );
      expect(container.read(searchQueryProvider), 'evening');
      tester.testTextInput.updateEditingValue(
        field.controller.value.replaced(field.controller.selection, 'night'),
      );
      await tester.pump();
      expect(container.read(searchQueryProvider), 'night');
    });
  }

  testWidgets('search shortcut leaves an open dialog in focus', (tester) async {
    UiProfile.debugOverride = UiProfile.desktop;
    await mount(tester);
    final field = tester.widget<EditableText>(find.byType(EditableText));
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(SearchPage)),
        builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
      ),
    );
    await tester.pumpAndSettle();
    final dialogField = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(EditableText),
      ),
    );
    await pressFind(tester, LogicalKeyboardKey.controlLeft);
    expect(dialogField.focusNode.hasFocus, isTrue);
    expect(field.focusNode.hasFocus, isFalse);
  });

  for (final desktop in [false, true]) {
    testWidgets('find ignores ${desktop ? 'inactive tab' : 'mobile search'}', (
      tester,
    ) async {
      UiProfile.debugOverride = desktop ? UiProfile.desktop : UiProfile.mobile;
      await mount(tester, active: !desktop);
      final field = tester.widget<EditableText>(find.byType(EditableText));
      field.focusNode.unfocus();
      await tester.pump();
      await pressFind(tester, LogicalKeyboardKey.controlLeft);
      expect(field.focusNode.hasFocus, isFalse);
    });
  }

  for (final profile in [UiProfile.mobile, UiProfile.desktop]) {
    testWidgets(
      'result menu closes before the playlist editor on ${profile.formFactor.name}',
      (tester) async {
        UiProfile.debugOverride = profile;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        await mount(tester);
        await tester.tap(find.byTooltip('More Actions').first);
        await tester.pumpAndSettle();
        final action = find.text('Save as Playlist');
        final menu = ModalRoute.of(tester.element(action))!;
        await tester.tap(action);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.widgetWithText(TextField, 'Playlist name'), findsNothing);
        await tester.pumpAndSettle();
        expect(menu.overlayEntries, isEmpty);
        expect(find.widgetWithText(TextField, 'Playlist name'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Evening light'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('source picker switches between installed source and library', (
    tester,
  ) async {
    final container = await mount(tester);
    await tester.tap(sourcePicker());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo source').last);
    await tester.pumpAndSettle();
    expect(container.read(searchSourceProvider), 'dev.lekis.test.music');
    expect(find.text('Evening light'), findsOneWidget);
    await tester.tap(sourcePicker());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library').last);
    await tester.pumpAndSettle();
    expect(container.read(searchSourceProvider), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty library search offers enabled sources only on tap', (
    tester,
  ) async {
    final onlineQueries = <(String, String)>[];
    final container = await mount(
      tester,
      initialQuery: '夜航星',
      plugins: [
        source(),
        source(name: 'Other', id: 'other'),
        source(name: 'Disabled', id: 'disabled', enabled: false),
      ],
      loadResults: (ref) async {
        final selected = ref.watch(searchSourceProvider);
        final query = ref.watch(searchQueryProvider);
        if (selected != null) onlineQueries.add((selected, query));
        return const SearchResultsDto(tracks: [], albums: [], artists: []);
      },
    );
    expect(find.text('Search Demo source for “夜航星”'), findsOneWidget);
    expect(find.text('Search Disabled for “夜航星”'), findsNothing);
    expect(onlineQueries, isEmpty);
    await tester.tap(find.text('Search Other for “夜航星”'));
    await tester.pumpAndSettle();
    expect(onlineQueries, [('other', '夜航星')]);
    expect(container.read(searchQueryProvider), '夜航星');
    expect(find.text('Search Demo source for “夜航星”'), findsNothing);
  });

  testWidgets(
    'disabled selected source is explicit and can return to local search',
    (tester) async {
      final container = await mount(
        tester,
        selected: 'dev.lekis.test.music',
        plugins: [source(enabled: false)],
      );
      expect(find.text('Source unavailable'), findsOneWidget);
      await tester.tap(sourcePicker());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library').last);
      await tester.pumpAndSettle();
      expect(container.read(searchSourceProvider), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['query', 'source', 'refresh']) {
    testWidgets(
      '$change loading hides retained results and failure shows current error',
      (tester) async {
        final request = Completer<SearchResultsDto?>();
        var calls = 0;
        final container = await mount(
          tester,
          loadResults: (ref) async {
            ref.watch(searchQueryProvider);
            ref.watch(searchSourceProvider);
            return calls++ == 0 ? results : request.future;
          },
        );
        expect(find.text('Evening light'), findsOneWidget);

        switch (change) {
          case 'query':
            container
                .read(searchQueryProvider.notifier)
                .set('https://www.youtube.com/watch?v=unavailable');
          case 'source':
            container
                .read(searchSourceProvider.notifier)
                .set('dev.lekis.test.music');
          case 'refresh':
            container.invalidate(searchResultsProvider);
        }
        await tester.pump();
        final pending = container.read(searchResultsProvider);
        expect(pending.isLoading, isTrue);
        expect(pending.hasValue, isTrue);
        expect(pending.value, same(results));
        // No old row survives the skeleton delay or its outgoing animation,
        // so pointer and keyboard users cannot play the previous request.
        expect(find.text('Evening light'), findsNothing);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Evening light'), findsNothing);

        request.completeError(StateError('$change request unavailable'));
        await tester.pumpAndSettle();
        final failed = container.read(searchResultsProvider);
        // This is a real FutureProvider refresh error with retained data,
        // rather than a synthetic AsyncError with no previous successful data.
        expect(failed.hasError, isTrue);
        expect(failed.isLoading, isFalse);
        expect(failed.hasValue, isTrue);
        expect(failed.value, same(results));
        expect(find.text('Load Failed'), findsOneWidget);
        expect(
          find.textContaining('$change request unavailable'),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Evening light'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(calls, 3); // The button explicitly starts a new request.
        expect(find.text('Evening light'), findsNothing);
      },
    );
  }

  for (final desktop in [false, true]) {
    testWidgets('long source name fits 320dp desktop=$desktop', (tester) async {
      UiProfile.debugOverride = desktop ? UiProfile.desktop : UiProfile.mobile;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 844);
      addTearDown(tester.view.reset);
      final container = await mount(
        tester,
        selected: 'dev.lekis.test.music',
        plugins: [
          source(name: 'An unusually long installed music source name'),
        ],
      );
      expect(find.text('Browse source'), findsOneWidget);
      expect(
        find.byType(SettingsComboBox<String>),
        desktop ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      if (desktop) {
        await tester.tap(find.byType(OutlinedButton));
      } else {
        await tester.tap(sourcePicker());
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library').last);
      await tester.pumpAndSettle();
      expect(container.read(searchSourceProvider), isNull);
      expect(find.text('Browse source'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final desktop in [false, true]) {
    for (final dark in [false, true]) {
      final name =
          '${desktop ? 'desktop' : 'phone'}-${dark ? 'dark' : 'light'}';
      testWidgets('source search layout $name', (tester) async {
        UiProfile.debugOverride = desktop
            ? UiProfile.desktop
            : UiProfile.mobile;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = desktop
            ? const Size(1280, 820)
            : const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await mount(tester, selected: 'dev.lekis.test.music', dark: dark);
        expect(find.text('Evening light'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final output = Platform.environment['LEKIS_UI_CAPTURE_DIR'];
        await capture(tester, output, name);
      });
    }
  }
}
