import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_panel.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _Playback extends PlaybackController {
  @override
  PlaybackUiState build() =>
      const PlaybackUiState(queueIndex: 0, queueLength: 1205);

  void edited() => state = state.copyWith(queueVersion: state.queueVersion + 1);
}

class _QueueApi implements RustLibApi {
  final ids = List.generate(1205, (index) => index == 1200 ? 4 : index);
  final reads = <(int, int)>[];
  final moves = <(int, int)>[];
  List<int>? played;
  int? start;
  Completer<void>? gate;

  @override
  Future<List<TrackRowDto>> crateApiCoreQueueItems({
    required int offset,
    required int limit,
  }) async {
    reads.add((offset, limit));
    final page = [
      for (final id in ids.skip(offset).take(limit))
        TrackRowDto(
          id: id,
          title: id == 4 ? 'Echo' : 'Track $id',
          artistLine: id == 620 ? 'ECHO artist' : 'Artist',
          durationMs: BigInt.zero,
          loved: false,
          isLocal: true,
        ),
    ];
    if (offset == 500 && gate != null) await gate!.future;
    return page;
  }

  @override
  void crateApiCorePlayTracks({
    required Int64List trackIds,
    required int start,
  }) {
    played = trackIds.map((id) => id.toInt()).toList();
    this.start = start;
  }

  @override
  void crateApiCoreQueueMove({required int from, required int to}) {
    moves.add((from, to));
    ids.insert(to, ids.removeAt(from));
  }

  @override
  PlaybackSnapshotDto crateApiCorePlaybackSnapshot() => PlaybackSnapshotDto(
    state: PlaybackStateDto.playing,
    positionMs: BigInt.zero,
    durationMs: BigInt.zero,
    queueIndex: start,
    queueLen: ids.length,
    volume: 1,
    outputMode: OutputModeDto.shared,
    repeat: RepeatModeDto.off,
    shuffle: ShuffleModeDto.off,
    gapless: false,
    queueVersion: BigInt.from(moves.length),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _QueueApi api;
  late _Playback playback;
  late ProviderContainer container;
  setUp(() {
    api = _QueueApi();
    playback = _Playback();
    RustLib.initMock(api: api);
    container = ProviderContainer(
      overrides: [
        playbackProvider.overrideWith(() => playback),
        trackArtworkProvider.overrideWith((ref, id) async => null),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    RustLib.dispose();
  });

  Future<void> open(WidgetTester tester, Widget queue) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(body: queue),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder row(int index) => find.byKey(ValueKey('queue-filter.row-$index'));
  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump();
    await tester.pump();
  }

  for (final desktop in [true, false]) {
    testWidgets(
      '${desktop ? 'panel' : 'preview'} filters the whole queue and acts on occurrences',
      (tester) async {
        final original = List.of(api.ids);
        await open(tester, desktop ? const QueuePanel() : const QueueList());
        await type(tester, ' eChO ');
        expect(find.text('Echo'), findsNWidgets(2));
        expect(row(4), findsOneWidget);
        expect(row(620), findsOneWidget);
        expect(row(1200), findsOneWidget);
        expect(
          tester.getTopLeft(row(620)).dy,
          lessThan(tester.getTopLeft(row(1200)).dy),
        );
        final reads = api.reads.length;
        await type(tester, 'no such track');
        expect(find.text('没有匹配的曲目'), findsOneWidget);
        await type(tester, 'echo');
        expect(api.reads.length, reads);
        expect(api.played, isNull);
        expect(api.moves, isEmpty);

        await tester.tap(row(1200));
        await tester.pump();
        expect(api.start, 1200);
        expect(api.played, orderedEquals(original));
        expect(api.reads.length, reads);
        await tester.pump(const Duration(seconds: 2));

        await tester.tap(
          find.descendant(of: row(1200), matching: find.byTooltip('移到下一首')),
        );
        expect(api.moves, [(1200, 1)]);
        playback.edited();
        await tester.pumpAndSettle();
        expect(row(1), findsOneWidget);
        expect(row(1200), findsNothing);
        await tester.tap(find.byTooltip('清除筛选'));
        await tester.pumpAndSettle();
        expect(find.text('Track 0'), findsOneWidget);
        expect(
          api.ids,
          orderedEquals(
            List.of(original)
              ..insert(1, original[1200])
              ..removeAt(1201),
          ),
        );
        expect(api.moves, [(1200, 1)]);
      },
    );
  }

  testWidgets(
    'an outstanding page follows the latest query and stops on clear',
    (tester) async {
      await open(tester, const QueueList());
      api.gate = Completer<void>();
      await type(tester, 'echo');
      expect(row(4), findsOneWidget);
      await type(tester, 'Track 620');
      expect(row(4), findsNothing);
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(row(620), findsOneWidget);
      expect(row(1200), findsNothing);

      api.gate = Completer<void>();
      playback.edited();
      await tester.pump();
      await tester.pump();
      final reads = api.reads.length;
      await tester.tap(find.byTooltip('清除筛选'));
      await tester.pump();
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(api.reads.length, reads);
      expect(find.text('Track 0'), findsOneWidget);
      expect(api.played, isNull);
      expect(api.moves, isEmpty);
    },
  );

  testWidgets('phone sheet keeps matches above the software keyboard', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 680);
    addTearDown(tester.view.reset);
    await open(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showQueueSheet(context),
          child: const Text('Open queue'),
        ),
      ),
    );
    await tester.tap(find.text('Open queue'));
    await tester.pumpAndSettle();
    final queueTitle = find.text('播放队列');
    final originalTop = tester.getTopLeft(queueTitle);
    final host = tester.element(queueTitle);
    unawaited(
      showDialog<void>(
        context: host,
        builder: (_) => const AlertDialog(content: TextField()),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(queueTitle), originalTop);
    Navigator.of(host).pop();
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await type(tester, 'Track 1199');
    expect(row(1199).hitTestable(), findsOneWidget);
    expect(tester.getBottomLeft(row(1199)).dy, lessThanOrEqualTo(400));
    expect(tester.takeException(), isNull);
  });

  test('a queue edit during paged playback cancels the stale jump', () async {
    final actions = container.read(playerActionsProvider);
    api.gate = Completer<void>();
    final play = actions.playQueueAt(1200);
    await Future<void>.delayed(Duration.zero);
    expect(api.reads, [(0, 500), (500, 500)]);
    playback.edited();
    api.gate!.complete();
    await play;
    expect(api.played, isNull);
  });
}
