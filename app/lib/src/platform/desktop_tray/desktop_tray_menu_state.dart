// Pure mapping from playback state to the Windows tray menu.
//
// Kept free of plugin types so it can be unit-tested on any host. The actual
// controller only translates this model into native menu item labels and
// enabled flags.

import 'package:flutter/foundation.dart';

import '../../features/player/player_providers.dart';

@immutable
class DesktopTrayMenuState {
  const DesktopTrayMenuState({required this.isPlaying, required this.hasTrack});

  factory DesktopTrayMenuState.fromPlayback(PlaybackUiState playback) {
    return DesktopTrayMenuState(
      isPlaying: playback.isPlaying,
      hasTrack: playback.hasTrack,
    );
  }

  final bool isPlaying;
  final bool hasTrack;

  String get playPauseLabel => isPlaying ? '暂停' : '播放';

  String get previousLabel => '上一首';

  String get nextLabel => '下一首';

  String get windowLabel => '显示/隐藏主窗口';

  String get quitLabel => '退出';

  /// Track-dependent commands are disabled until a queue item exists.
  bool get mediaEnabled => hasTrack;
}
