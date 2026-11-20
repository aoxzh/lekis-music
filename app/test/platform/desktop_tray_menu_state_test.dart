import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/platform/desktop_tray/desktop_tray_menu_state.dart';
import 'package:lekis/src/rust/api/dto.dart';

void main() {
  group('DesktopTrayMenuState.fromPlayback', () {
    test('shows pause while the core is playing', () {
      final state = DesktopTrayMenuState.fromPlayback(
        const PlaybackUiState(state: PlaybackStateDto.playing, trackId: 7),
      );

      expect(state.playPauseLabel, '暂停');
      expect(state.mediaEnabled, isTrue);
      expect(state.previousLabel, '上一首');
      expect(state.nextLabel, '下一首');
      expect(state.windowLabel, '显示/隐藏主窗口');
      expect(state.quitLabel, '退出');
    });

    test('shows play while paused or idle', () {
      for (final playback in const [
        PlaybackUiState(state: PlaybackStateDto.paused, trackId: 7),
        PlaybackUiState(state: PlaybackStateDto.idle),
      ]) {
        final state = DesktopTrayMenuState.fromPlayback(playback);
        expect(state.playPauseLabel, '播放');
      }
    });

    test('counts loading and buffering as playing, like the in-app button', () {
      for (final playback in const [
        PlaybackUiState(state: PlaybackStateDto.loading, trackId: 7),
        PlaybackUiState(state: PlaybackStateDto.buffering, trackId: 7),
      ]) {
        expect(
          DesktopTrayMenuState.fromPlayback(playback).playPauseLabel,
          '暂停',
        );
      }
    });

    test('disables transport items when the queue is empty', () {
      final state = DesktopTrayMenuState.fromPlayback(
        const PlaybackUiState(state: PlaybackStateDto.idle),
      );

      expect(state.playPauseLabel, '播放');
      expect(state.mediaEnabled, isFalse);
    });

    test('keeps the transport enabled for a paused track', () {
      final state = DesktopTrayMenuState.fromPlayback(
        const PlaybackUiState(state: PlaybackStateDto.paused, trackId: 42),
      );

      expect(state.mediaEnabled, isTrue);
    });
  });
}
