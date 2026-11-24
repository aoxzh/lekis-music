import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

TrackRowDto _row(int index) => TrackRowDto(
  id: 2000 + index,
  title: '曲目 $index',
  artistLine: '月兔',
  albumTitle: '月面',
  durationMs: BigInt.from(180000),
  loved: false,
  isLocal: false,
);

class _FakePlayback extends PlaybackController {
  _FakePlayback(this.queueIndex, this.queueLength);

  final int queueIndex;
  final int queueLength;

  void queueEdited() =>
      state = state.copyWith(queueVersion: state.queueVersion + 1);

  @override
  PlaybackUiState build() => PlaybackUiState(
    state: PlaybackStateDto.playing,
    trackId: 2000 + queueIndex,
    durationMs: 180000,
    queueLength: queueLength,
    queueIndex: queueIndex,
  );
}

class _FakeActions extends PlayerActions {
  _FakeActions(super.ref);

  final played = <int>[];
  final removed = <int>[];
  final moved = <(int, int)>[];

  @override
  Future<void> playQueueAt(
    int index, {
    Iterable<int> loadedIds = const [],
  }) async => played.add(index);

  @override
  void removeQueueAt(int index) => removed.add(index);

  @override
  void moveQueueItem(int from, int to) => moved.add((from, to));
}

void main() {
  testWidgets('move to next uses the selected occurrence in the preview', (
    tester,
  ) async {
    final playback = _FakePlayback(5, 20);
    late _FakeActions actions;
    final container = ProviderContainer(
      overrides: [
        playbackProvider.overrideWith(() => playback),
        queuePreviewProvider.overrideWith(
          (ref) async => [_row(4), _row(5), _row(6), _row(5), _row(8)],
        ),
        playerActionsProvider.overrideWith(
          (ref) => actions = _FakeActions(ref),
        ),
        trackArtworkProvider.overrideWith((ref, id) async => null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: const Scaffold(body: QueueList()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> openMenu(int row) async {
      await tester.tap(find.byTooltip('队列操作').at(row));
      await tester.pumpAndSettle();
    }

    for (final row in [1, 2]) {
      await openMenu(row);
      expect(find.text('移到下一首'), findsNothing);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
    }

    await openMenu(3);
    await tester.tap(find.text('移到下一首'));
    await tester.pumpAndSettle();
    expect(actions.moved, [(7, 6)]);
    expect(actions.played, isEmpty);
    expect(actions.removed, isEmpty);

    await openMenu(4);
    playback.queueEdited();
    await tester.pump();
    await tester.tap(find.text('移到下一首'));
    await tester.pumpAndSettle();
    expect(actions.moved, [(7, 6)]);
    expect(find.text('队列已变化，请重新选择曲目'), findsOneWidget);
  });

  testWidgets(
    'QueueList maps tap and remove through queuePreviewStart offset',
    (tester) async {
      // Queue has 20 tracks, playing index 5 -> preview window starts at 4.
      const currentIndex = 5;
      const start = 4;
      expect(queuePreviewStart(20, currentIndex), start);

      late _FakeActions actions;
      final container = ProviderContainer(
        overrides: [
          playbackProvider.overrideWith(() => _FakePlayback(currentIndex, 20)),
          queuePreviewProvider.overrideWith(
            (ref) async => [for (var i = 0; i < 4; i++) _row(start + i)],
          ),
          playerActionsProvider.overrideWith(
            (ref) => actions = _FakeActions(ref),
          ),
          trackArtworkProvider.overrideWith((ref, trackId) async => null),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: lekisDarkTheme(),
            home: const Scaffold(body: QueueList()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the third visible item -> actual queue index 4 + 2 = 6.
      await tester.tap(find.text('曲目 6'));
      await tester.pump();
      expect(actions.played, [6]);

      // Remove the second visible item via its overflow menu -> actual index 5.
      await tester.tap(find.byTooltip('队列操作').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从队列移除'));
      await tester.pump();
      // The row collapses first; the core is asked once it is out of sight.
      expect(actions.removed, isEmpty);
      await tester.pumpAndSettle();
      expect(actions.removed, [5]);

      // Drag handles are present for touch reordering.
      expect(find.byIcon(Icons.drag_handle_rounded), findsNWidgets(4));
    },
  );
}
