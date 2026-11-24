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

PluginInfoDto source({bool enabled = true, String name = 'Demo source'}) =>
    PluginInfoDto(
      id: 'dev.lekis.test.music',
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
      find.byType(DropdownButton<String>).evaluate().isNotEmpty
      ? find.byType(DropdownButton<String>)
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
      for (final family in ['Roboto', '.AppleSystemUIFont', 'Ahem']) {
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
    Future<SearchResultsDto?> Function(Ref ref)? loadResults,
  }) async {
    final container = ProviderContainer.test(
      overrides: [
        playbackProvider.overrideWith(IdlePlayback.new),
        trackArtworkProvider.overrideWith((ref, id) async => null),
        pluginListProvider.overrideWith(() => Sources(plugins ?? [source()])),
        searchSourceProvider.overrideWith(() => SimpleValue<String?>(selected)),
        searchQueryProvider.overrideWith(() => SimpleValue<String>('evening')),
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
          locale: const Locale('en'),
          child: MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: boundaryKey,
              child: TickerMode(enabled: active, child: const SearchPage()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> pressFind(
    WidgetTester tester,
    LogicalKeyboardKey modifier,
  ) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

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
        final picker = tester.widget<DropdownButton<String>>(
          find.byType(DropdownButton<String>),
        );
        expect(picker.underline, isA<SizedBox>());
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
        if (output != null) {
          await tester.runAsync(() async {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(output).create(recursive: true);
            await File('$output/$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
