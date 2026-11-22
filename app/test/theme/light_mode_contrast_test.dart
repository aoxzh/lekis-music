import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/enrich/enrich_actions.dart';
import 'package:lekis/src/features/enrich/enrich_progress.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  testWidgets('浅色与深色模式下 ChoiceChip 选中/未选中文字均满足 WCAG AA 对比度', (
    tester,
  ) async {
    for (final (name, theme, colors) in [
      ('light', lekisLightTheme(), LekisColors.light),
      ('dark', lekisDarkTheme(), LekisColors.dark),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: true,
                  onSelected: (_) {},
                ),
                ChoiceChip(
                  label: const Text('商业'),
                  selected: false,
                  onSelected: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Color textColorOf(String label) {
        final ctx = tester.element(find.text(label));
        return DefaultTextStyle.of(ctx).style.color!;
      }

      final selectedColor = textColorOf('全部');
      final unselectedColor = textColorOf('商业');

      expect(
        _contrastRatio(selectedColor, colors.accentSoft),
        greaterThanOrEqualTo(4.5),
        reason: '$name 选中态 ChoiceChip 文字对比度不足: $selectedColor on ${colors.accentSoft}',
      );
      expect(
        _contrastRatio(unselectedColor, colors.surfaceVariant),
        greaterThanOrEqualTo(4.5),
        reason:
            '$name 未选中态 ChoiceChip 文字对比度不足: $unselectedColor on ${colors.surfaceVariant}',
      );
      if (name == 'light') {
        expect(selectedColor, isNot(Colors.white));
        expect(unselectedColor, isNot(Colors.white));
      }
    }
  });

  test('浅色模式 lightMoon 对比度在浅底与柔和强调底上均达到 WCAG AA', () {
    expect(
      _contrastRatio(LekisPalette.lightMoon, LekisPalette.lightBackground),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrastRatio(LekisPalette.lightMoon, LekisPalette.lightSurface),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrastRatio(LekisPalette.lightMoon, LekisPalette.lightAccentSoft),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('本地曲目菜单不显示下载，远程曲目正常显示下载', (tester) async {
    TrackRowDto makeTrack({required int id, required bool isLocal}) =>
        TrackRowDto(
          id: id,
          title: isLocal ? '本地曲目' : 'NAS 曲目',
          artistLine: '测试艺人',
          albumTitle: '测试专辑',
          durationMs: BigInt.from(180000),
          artworkId: null,
          qualityBadge: 'FLAC',
          loved: false,
          isLocal: isLocal,
        );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackProvider.overrideWith(_IdlePlayback.new),
          downloadStateProvider.overrideWith((ref, id) => null),
          downloadProgressProvider.overrideWith((ref, id) => null),
        ],
        child: MaterialApp(
          theme: lekisLightTheme(),
          home: Scaffold(
            body: Column(
              children: [
                TrackTile(
                  track: makeTrack(id: 1, isLocal: true),
                  onTap: () {},
                ),
                TrackTile(
                  track: makeTrack(id: 2, isLocal: false),
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 右键打开本地曲目菜单：不应出现「下载」。
    await tester.tap(find.text('本地曲目'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('添加到歌单'), findsOneWidget);
    expect(find.text('下载'), findsNothing);

    // 关闭第一个菜单。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // 右键打开远程 NAS 曲目菜单：应出现「下载」。
    await tester.tap(find.text('NAS 曲目'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('下载'), findsOneWidget);
  });

  testWidgets('EnrichProgressBanner 在补全进行中展示进度条与计数', (tester) async {
    final container = ProviderContainer(
      overrides: [
        enrichProgressProvider.overrideWith(_RunningProgressNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisLightTheme(),
          home: const Scaffold(body: EnrichProgressBanner()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(EnrichProgressBanner.progressBarKey), findsOneWidget);
    expect(find.textContaining('3 / 10'), findsOneWidget);
    expect(find.textContaining('青春コンプレックス'), findsOneWidget);
  });
}

class _IdlePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState();
}

class _RunningProgressNotifier extends EnrichProgressNotifier {
  @override
  EnrichTaskProgress? build() => const EnrichTaskProgress(
    scope: EnrichScope.artwork,
    total: 10,
    completed: 3,
    autoApplied: 2,
    queued: 1,
    running: true,
    currentTitle: '青春コンプレックス',
  );
}
