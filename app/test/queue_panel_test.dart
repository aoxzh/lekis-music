// Desktop queue: third pane on wide windows, bottom sheet on compact ones.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/now_playing/now_playing_page.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_panel.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const _queueLength = 80;
const _queuePageSize = 20;

TrackRowDto _row(int index) => TrackRowDto(
  id: 1000 + index,
  title: '曲目 $index',
  artistLine: '月兔',
  albumTitle: '月面',
  durationMs: BigInt.from(180000),
  loved: false,
);

class _FakePlayback extends PlaybackController {
  _FakePlayback(this.queueIndex);

  final int queueIndex;

  @override
  PlaybackUiState build() => PlaybackUiState(
    state: PlaybackStateDto.playing,
    trackId: 1000 + queueIndex,
    durationMs: 240000,
    queueLength: _queueLength,
    queueIndex: queueIndex,
  );
}

class _FakePosition extends PositionController {
  @override
  int build() => 61000;
}

class _FakeActions extends PlayerActions {
  _FakeActions(super.ref);

  final played = <int>[];
  int removed = 0;
  int moved = 0;

  @override
  Future<void> playQueueAt(int index) async => played.add(index);

  @override
  void removeQueueAt(int index) => removed++;

  @override
  void moveQueueItem(int from, int to) => moved++;
}

PagedList<TrackRowDto> _queueList() => PagedList<TrackRowDto>(
  pageSize: _queuePageSize,
  count: () async => _queueLength,
  fetch: (offset, limit) async {
    final end = (offset + limit).clamp(0, _queueLength);
    return [for (var i = offset; i < end; i++) _row(i)];
  },
);

(ProviderContainer, _FakeActions, PagedList<TrackRowDto>) _container() {
  final list = _queueList();
  late _FakeActions actions;
  final container = ProviderContainer(
    overrides: [
      playbackProvider.overrideWith(() => _FakePlayback(40)),
      positionProvider.overrideWith(_FakePosition.new),
      currentTrackProvider.overrideWith((ref) async => null),
      currentArtworkProvider.overrideWith((ref) async => null),
      queuePreviewProvider.overrideWith(
        (ref) async => [for (var i = 0; i < 3; i++) _row(i)],
      ),
      queueListProvider.overrideWith((ref) => list),
      playerActionsProvider.overrideWith((ref) => actions = _FakeActions(ref)),
      trackArtworkProvider.overrideWith((ref, trackId) async => null),
    ],
  );
  container.read(playerActionsProvider);
  return (container, actions, list);
}

Widget _host(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: lekisDarkTheme(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: const NowPlayingPage(),
      ),
    ),
  ),
);

void main() {
  testWidgets('wide Now Playing shows the queue in a 320 dp third pane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final (container, actions, list) = _container();
    addTearDown(container.dispose);
    addTearDown(list.dispose);

    await tester.pumpWidget(_host(container));
    await tester.pumpAndSettle();

    // Opening the pane from the cover exercises the three-pane transition.
    await tester.tap(find.byKey(const ValueKey('now-playing.actions.queue')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('queue-panel')), findsOneWidget);
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.byType(QueueList), findsNothing);

    final size = tester.getSize(find.byKey(const ValueKey('queue-panel')));
    expect(size.width, QueuePanel.width);

    // The panel jumps to the current row, not the start of the queue.
    expect(find.text('曲目 40'), findsOneWidget);
    expect(find.text('80'), findsWidgets);

    final currentRow = find.byKey(const ValueKey('queue-panel.row-40'));
    await tester.tap(currentRow);
    await tester.pump();
    expect(actions.played, [40]);

    await tester.tap(
      find.descendant(of: currentRow, matching: find.byTooltip('上移')),
    );
    await tester.pump();
    expect(actions.moved, 1);

    await tester.tap(
      find.descendant(of: currentRow, matching: find.byTooltip('从队列移除')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(actions.removed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact Now Playing keeps the queue bottom sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final (container, _, list) = _container();
    addTearDown(container.dispose);
    addTearDown(list.dispose);

    await tester.pumpWidget(_host(container));
    await tester.pumpAndSettle();

    expect(find.byType(QueuePanel), findsNothing);

    await tester.tap(find.byKey(const ValueKey('now-playing.actions.queue')));
    await tester.pumpAndSettle();

    expect(find.byType(QueueList), findsOneWidget);
    expect(find.byType(QueuePanel), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
