// Track rows: right-click opens the same menu as the ⋯ button.

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _IdlePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState();
}

void main() {
  for (final local in [false, true]) {
    for (final online in [false, true]) {
      testWidgets('right-click menu local=$local plugin=$online', (
        tester,
      ) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackProvider.overrideWith(_IdlePlayback.new),
              downloadStateProvider.overrideWith((ref, id) => null),
              downloadProgressProvider.overrideWith((ref, id) => null),
            ],
            child: MaterialApp(
              theme: lekisDarkTheme(),
              home: Scaffold(
                body: TrackTile(
                  track: TrackRowDto(
                    id: 1,
                    title: 'Song',
                    artistLine: 'Artist',
                    durationMs: BigInt.from(180000),
                    loved: false,
                    isLocal: local,
                  ),
                  onlinePlugin: online,
                  leadingNumber: 1,
                  onTap: () {},
                ),
              ),
            ),
          ),
        );

        expect(find.text('添加到歌单'), findsNothing);
        await tester.tap(find.text('Song'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(find.text('添加到歌单'), findsOneWidget);
        expect(find.text('编辑标签'), local ? findsOneWidget : findsNothing);
        expect(find.text('补全封面和歌词'), online ? findsNothing : findsOneWidget);
        expect(find.text('补全歌词'), online ? findsOneWidget : findsNothing);
        expect(find.text('更换封面…'), online ? findsNothing : findsOneWidget);
      });
    }
  }
}
