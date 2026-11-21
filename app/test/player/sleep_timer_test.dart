import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/sleep_timer.dart';
import 'package:lekis/src/rust/api/dto.dart';

class _FakePlaybackController extends PlaybackController {
  _FakePlaybackController(this._initial);
  final PlaybackUiState _initial;

  @override
  PlaybackUiState build() => _initial;

  void emit(PlaybackUiState next) => state = next;
}

class _SpyPlayerActions extends PlayerActions {
  _SpyPlayerActions(super.ref);
  int pauseCount = 0;

  @override
  void pause() {
    pauseCount++;
  }
}

void main() {
  group('SleepTimerNotifier (PLY-11)', () {
    test('endOfTrack pauses and resets when current track changes', () {
      late _FakePlaybackController playback;
      final container = ProviderContainer(
        overrides: [
          playbackProvider.overrideWith(() {
            playback = _FakePlaybackController(
              const PlaybackUiState(
                state: PlaybackStateDto.playing,
                trackId: 10,
                queueIndex: 0,
                queueLength: 2,
              ),
            );
            return playback;
          }),
          playerActionsProvider.overrideWith(_SpyPlayerActions.new),
        ],
      );
      addTearDown(container.dispose);
      final actions =
          container.read(playerActionsProvider) as _SpyPlayerActions;

      container
          .read(sleepTimerProvider.notifier)
          .set(SleepTimerKind.endOfTrack);
      expect(
        container.read(sleepTimerProvider).kind,
        SleepTimerKind.endOfTrack,
      );
      expect(container.read(sleepTimerProvider).active, isTrue);

      // 切到下一首：应立刻暂停并关闭定时。
      playback.emit(
        const PlaybackUiState(
          state: PlaybackStateDto.playing,
          trackId: 11,
          queueIndex: 1,
          queueLength: 2,
        ),
      );
      expect(actions.pauseCount, 1);
      expect(container.read(sleepTimerProvider).kind, SleepTimerKind.off);
      expect(container.read(sleepTimerProvider).active, isFalse);
    });

    test(
      'endOfTrack armed while idle captures first track then pauses on next',
      () {
        late _FakePlaybackController playback;
        final container = ProviderContainer(
          overrides: [
            playbackProvider.overrideWith(() {
              playback = _FakePlaybackController(const PlaybackUiState());
              return playback;
            }),
            playerActionsProvider.overrideWith(_SpyPlayerActions.new),
          ],
        );
        addTearDown(container.dispose);
        final actions =
            container.read(playerActionsProvider) as _SpyPlayerActions;

        container
            .read(sleepTimerProvider.notifier)
            .set(SleepTimerKind.endOfTrack);
        playback.emit(
          const PlaybackUiState(
            state: PlaybackStateDto.playing,
            trackId: 20,
            queueIndex: 0,
            queueLength: 2,
          ),
        );
        // 刚开始播放第一首时不该暂停。
        expect(actions.pauseCount, 0);
        expect(
          container.read(sleepTimerProvider).kind,
          SleepTimerKind.endOfTrack,
        );

        // 播完进入第二首时触发暂停。
        playback.emit(
          const PlaybackUiState(
            state: PlaybackStateDto.playing,
            trackId: 21,
            queueIndex: 1,
            queueLength: 2,
          ),
        );
        expect(actions.pauseCount, 1);
        expect(container.read(sleepTimerProvider).kind, SleepTimerKind.off);
      },
    );

    test(
      'endOfTrack triggers when same track advances to next queue index',
      () {
        late _FakePlaybackController playback;
        final container = ProviderContainer(
          overrides: [
            playbackProvider.overrideWith(() {
              playback = _FakePlaybackController(
                const PlaybackUiState(
                  state: PlaybackStateDto.playing,
                  trackId: 5,
                  queueIndex: 0,
                  queueLength: 2,
                ),
              );
              return playback;
            }),
            playerActionsProvider.overrideWith(_SpyPlayerActions.new),
          ],
        );
        addTearDown(container.dispose);
        final actions =
            container.read(playerActionsProvider) as _SpyPlayerActions;

        container
            .read(sleepTimerProvider.notifier)
            .set(SleepTimerKind.endOfTrack);
        playback.emit(
          const PlaybackUiState(
            state: PlaybackStateDto.playing,
            trackId: 5,
            queueIndex: 1,
            queueLength: 2,
          ),
        );
        expect(actions.pauseCount, 1);
        expect(container.read(sleepTimerProvider).kind, SleepTimerKind.off);
      },
    );

    test('cancelling endOfTrack prevents pause on subsequent track change', () {
      late _FakePlaybackController playback;
      final container = ProviderContainer(
        overrides: [
          playbackProvider.overrideWith(() {
            playback = _FakePlaybackController(
              const PlaybackUiState(
                state: PlaybackStateDto.playing,
                trackId: 1,
                queueIndex: 0,
                queueLength: 2,
              ),
            );
            return playback;
          }),
          playerActionsProvider.overrideWith(_SpyPlayerActions.new),
        ],
      );
      addTearDown(container.dispose);
      final actions =
          container.read(playerActionsProvider) as _SpyPlayerActions;

      container
          .read(sleepTimerProvider.notifier)
          .set(SleepTimerKind.endOfTrack);
      container.read(sleepTimerProvider.notifier).cancel();
      playback.emit(
        const PlaybackUiState(
          state: PlaybackStateDto.playing,
          trackId: 2,
          queueIndex: 1,
          queueLength: 2,
        ),
      );
      expect(actions.pauseCount, 0);
    });
  });
}
