// Desktop player bar must fit its fixed height at common window sizes
// (a RenderFlex overflow fails the test via FlutterError).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
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
  );
}

class _FakePosition extends PositionController {
  @override
  int build() => 61000;
}

void main() {
  for (final size in const [
    Size(1280, 820),
    Size(900, 600),
    Size(1920, 1080),
  ]) {
    testWidgets(
      'PlayerBar fits at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              coreEventSourceProvider.overrideWithValue(const Stream.empty()),
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
      },
    );
  }
}
