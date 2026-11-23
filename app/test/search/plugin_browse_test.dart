import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/plugins/plugin_browse_page.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/features/sources/common.dart';

import 'source_search_test.dart' show IdlePlayback, results;

void main() {
  final boundaryKey = GlobalKey();
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
  Future<void> mount(
    WidgetTester tester,
    Future<PluginBrowsePageDto> Function(PluginBrowseRequest) load, {
    bool dark = false,
  }) async {
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
      ProviderScope(
        overrides: [
          playbackProvider.overrideWith(IdlePlayback.new),
          trackArtworkProvider.overrideWith((ref, id) async => null),
          pluginBrowseProvider.overrideWith((ref, request) => load(request)),
        ],
        child: LekisLocale(
          locale: const Locale('en'),
          child: MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: boundaryKey,
              child: const PluginBrowsePage(
                pluginId: 'dev.mygo.test',
                title: 'Music',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('folders navigate using opaque paths and preserve source', (
    tester,
  ) async {
    final requests = <PluginBrowseRequest>[];
    await mount(tester, (request) async {
      requests.add(request);
      return request.path.isEmpty
          ? const PluginBrowsePageDto(
              folders: [PluginFolderDto(id: 'page:charts', title: 'Charts')],
              tracks: [],
            )
          : PluginBrowsePageDto(folders: [], tracks: results.tracks);
    });
    await tester.tap(find.text('Charts'));
    await tester.pumpAndSettle();
    expect(requests.last.path, 'page:charts');
    expect(requests.last.pluginId, 'dev.mygo.test');
    expect(find.text('Evening light'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pagination retries without losing rows and deduplicates IDs', (
    tester,
  ) async {
    var attempts = 0;
    await mount(tester, (request) async {
      if (request.cursor != null && attempts++ == 0) {
        throw Exception('Page unavailable');
      }
      return PluginBrowsePageDto(
        folders: [],
        tracks: results.tracks,
        next: request.cursor == null ? 'second' : null,
      );
    });
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(find.text('Evening light'), findsOneWidget);
    expect(
      find.text(describeCoreError(Exception('Page unavailable'))),
      findsOneWidget,
    );
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(find.text('Evening light'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });
  for (final desktop in [false, true]) {
    for (final dark in [false, true]) {
      final name =
          'browse-${desktop ? "desktop" : "phone"}-${dark ? "dark" : "light"}';
      testWidgets('browse layout $name', (tester) async {
        UiProfile.debugOverride = desktop
            ? UiProfile.desktop
            : UiProfile.mobile;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = desktop
            ? const Size(1280, 820)
            : const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await mount(
          tester,
          (_) async => PluginBrowsePageDto(
            folders: const [
              PluginFolderDto(
                id: 'page:charts',
                title: 'Music charts',
                subtitle: 'Weekly music ranking',
              ),
            ],
            tracks: results.tracks,
            next: 'next',
          ),
          dark: dark,
        );
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
