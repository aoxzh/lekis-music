// Guards for the shared chrome:
// * empty states show only the brand mark (no halo circle / badge);
// * the mini player uses the tab bar's capsule in both tab bar styles;
// * the desktop player bar keeps lyrics / queue / devices in its right
//   cluster and toggles the side panel in place;
// * the lyrics and tag editors are a dialog on wide windows and a bottom
//   sheet on phones, built from the same panel.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/library/tag_editor_dialog.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/now_playing/lyrics_editor_sheet.dart';
import 'package:lekis/src/features/player/mini_player.dart';
import 'package:lekis/src/features/player/player_bar.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:lekis/src/widgets/brand_mark.dart';
import 'package:lekis/src/widgets/liquid_glass.dart';
import 'package:material_ui/material_ui.dart';

class _FakePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.playing,
    trackId: 1,
    durationMs: 240000,
    queueLength: 3,
    queueIndex: 0,
  );
}

class _FakePosition extends PositionController {
  @override
  int build() => 1000;
}

ProviderContainer _container() => ProviderContainer(
  overrides: [
    coreEventSourceProvider.overrideWithValue(const Stream.empty()),
    playbackProvider.overrideWith(_FakePlayback.new),
    positionProvider.overrideWith(_FakePosition.new),
    currentTrackProvider.overrideWith((ref) async => null),
    currentArtworkProvider.overrideWith((ref) async => null),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child, {
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: lekisDarkTheme(),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('empty state shows just the brand mark', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pump(
      tester,
      container,
      const LekisEmptyState(title: '欢迎使用 Lekis', message: 'msg'),
    );

    final mark = find.byType(LekisBrandMark);
    expect(mark, findsOneWidget);
    expect(tester.widget<LekisBrandMark>(mark).ring, isFalse);
    // No circular halo / dots around the mark.
    final circles = find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle,
    );
    expect(circles, findsNothing);
    expect(find.byIcon(Icons.nightlight_round), findsNothing);
  });

  for (final style in TabBarStyle.values) {
    testWidgets('mini player matches the ${style.name} tab bar', (
      tester,
    ) async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(tabBarStyleProvider.notifier).restore(style);
      await _pump(
        tester,
        container,
        const Align(alignment: Alignment.bottomCenter, child: MiniPlayer()),
        size: const Size(400, 800),
      );
      final capsule = tester.widget<LekisGlassCapsule>(
        find.byKey(MiniPlayerFace.cardKey),
      );
      expect(capsule.flat, style == TabBarStyle.flat);
      expect(capsule.radius, LekisRadius.miniPlayer);
      expect(
        find.byType(LiquidGlass),
        style == TabBarStyle.flat ? findsNothing : findsOneWidget,
      );
    });
  }

  testWidgets('player bar: lyrics / queue / devices sit right, toggle panel', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pump(
      tester,
      container,
      const Align(
        alignment: Alignment.bottomCenter,
        child: PlayerBar(sidePanel: true),
      ),
    );

    final bar = tester.getRect(find.byType(PlayerBar));
    for (final key in const [
      PlayerBar.lyricsKey,
      PlayerBar.queueKey,
      PlayerBar.devicesKey,
    ]) {
      final rect = tester.getRect(find.byKey(key));
      expect(rect.left, greaterThan(bar.width * 0.6));
      expect(rect.center.dy, closeTo(bar.center.dy, LekisSpacing.lg));
    }

    await tester.tap(find.byKey(PlayerBar.lyricsKey));
    await tester.pump();
    expect(container.read(desktopSidePaneProvider), DesktopSidePane.lyrics);
    await tester.tap(find.byKey(PlayerBar.queueKey));
    await tester.pump();
    expect(container.read(desktopSidePaneProvider), DesktopSidePane.queue);
    await tester.tap(find.byKey(PlayerBar.queueKey));
    await tester.pump();
    expect(container.read(desktopSidePaneProvider), isNull);
    expect(tester.takeException(), isNull);
  });

  for (final wide in [true, false]) {
    final size = wide ? const Size(1280, 800) : const Size(400, 800);
    final kind = wide ? 'dialog' : 'bottom sheet';

    testWidgets('tag editor opens as a $kind', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pump(
        tester,
        container,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showBatchTagEditor(context, trackIds: [1, 2]),
            child: const Text('open'),
          ),
        ),
        size: size,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(LekisPanel), findsOneWidget);
      expect(find.byType(Dialog), wide ? findsOneWidget : findsNothing);
      expect(find.byType(BottomSheet), wide ? findsNothing : findsOneWidget);
      expect(find.text('批量编辑标签'), findsOneWidget);
      // Fields use the theme's filled style, not a stroked outline.
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.decoration?.border, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lyrics editor opens as a $kind', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pump(
        tester,
        container,
        Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () => showLyricsEditor(context, ref, 1),
            child: const Text('open'),
          ),
        ),
        size: size,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(LekisPanel), findsOneWidget);
      expect(find.byType(Dialog), wide ? findsOneWidget : findsNothing);
      expect(find.byType(BottomSheet), wide ? findsNothing : findsOneWidget);
      expect(find.text('编辑歌词'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
