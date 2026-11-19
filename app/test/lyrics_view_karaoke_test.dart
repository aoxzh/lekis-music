// 歌词舞台接入 LyricsView：整行文本给语义树，逐字进度由舞台 painter 负责。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage_settings.dart';
import 'package:lekis/src/features/now_playing/lyrics_view.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.playing,
    trackId: 1,
    durationMs: 180000,
  );
}

class _FakePosition extends PositionController {
  @override
  int build() => 5300;
}

void main() {
  testWidgets('LyricsView renders enhanced LRC through the stage', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final lyrics = ParsedLyrics.parse(
      LyricsDto(
        format: LyricsFormatDto.enhancedLrc,
        content: '[00:05.00]<00:05.00>hello <00:05.40>world\n[00:08.00]next',
        source: 'test',
        offsetMs: 0,
        confidence: 1,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackProvider.overrideWith(_FakePlayback.new),
          positionProvider.overrideWith(_FakePosition.new),
          lyricsProvider.overrideWith((ref, trackId) async => lyrics),
          lyricsStageStyleProvider.overrideWithValue(LyricsStageStyle.flow),
          lyricsSparksProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: const Scaffold(body: LyricsView(trackId: 1)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    final semantics = tester.ensureSemantics();
    // 语义只暴露整行，不暴露逐字 span。
    expect(find.bySemanticsLabel('hello world'), findsOneWidget);
    semantics.dispose();
  });
}
