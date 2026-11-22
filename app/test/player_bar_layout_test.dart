// Desktop player bar must fit its fixed height at common window sizes
// (a RenderFlex overflow fails the test via FlutterError).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_controller.dart';
import 'package:lekis/src/features/player/player_bar.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.playing,
    trackId: 1,
    durationMs: 240000,
    queueLength: 3,
    queueIndex: 0,
    volume: 0.8,
  );
}

class _FakePosition extends PositionController {
  @override
  int build() => 61000;
}

class _SpyPlayerActions extends PlayerActions {
  _SpyPlayerActions(super.ref);
  double? lastVolume;

  @override
  void setVolume(double volume) {
    lastVolume = volume;
  }
}

void main() {
  for (final size in const [
    Size(840, 600),
    Size(900, 600),
    Size(1280, 820),
    Size(1920, 1080),
  ]) {
    testWidgets(
      'PlayerBar fits at ${size.width.toInt()}x${size.height.toInt()} with all desktop controls',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              coreEventSourceProvider.overrideWithValue(const Stream.empty()),
              desktopLyricsSupportedProvider.overrideWithValue(true),
              playbackProvider.overrideWith(_FakePlayback.new),
              positionProvider.overrideWith(_FakePosition.new),
              currentTrackProvider.overrideWith((ref) async => null),
              currentArtworkProvider.overrideWith((ref) async => null),
            ],
            child: MaterialApp(
              theme: lekisDarkTheme(),
              home: const Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: PlayerBar(),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        final volRect = tester.getRect(find.byKey(PlayerBar.volumeKey));
        expect(volRect.right, lessThanOrEqualTo(size.width));
      },
    );
  }

  testWidgets('tapping volume icon opens floating vertical slider popover', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late _SpyPlayerActions actions;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreEventSourceProvider.overrideWithValue(const Stream.empty()),
          desktopLyricsSupportedProvider.overrideWithValue(true),
          playbackProvider.overrideWith(_FakePlayback.new),
          positionProvider.overrideWith(_FakePosition.new),
          playerActionsProvider.overrideWith((ref) {
            actions = _SpyPlayerActions(ref);
            return actions;
          }),
          currentTrackProvider.overrideWith((ref) async => null),
          currentArtworkProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: const Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: PlayerBar()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(PlayerBar.volumePopoverKey), findsNothing);
    await tester.tap(find.byKey(PlayerBar.volumeKey));
    await tester.pumpAndSettle();

    final popover = find.byKey(PlayerBar.volumePopoverKey);
    expect(popover, findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    final popRect = tester.getRect(popover);
    // 浮层在窗口内部完整可见，不超出右侧边界。
    expect(popRect.right, lessThanOrEqualTo(900));
    expect(popRect.top, greaterThanOrEqualTo(0));

    // 点击浮层里的静音按钮。
    await tester.tap(find.byTooltip('静音'));
    await tester.pump();
    expect(actions.lastVolume, 0);

    // 点击空白处收起浮层。
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byKey(PlayerBar.volumePopoverKey), findsNothing);
  });
}
