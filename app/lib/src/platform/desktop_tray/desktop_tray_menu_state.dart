// Pure mapping from playback state to the Windows tray menu.
//
// Kept free of plugin types so it can be unit-tested on any host. The actual
// controller only translates this model into native menu item labels and
// enabled flags.

import 'package:flutter/foundation.dart';

import '../../features/player/player_providers.dart';
import '../../l10n/app_l10n.dart';

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

  String get playPauseLabel => isPlaying
      ? L10n.tr('暂停', 'Pause')
      : L10n.tr('播放', 'Play');

  String get previousLabel => L10n.tr('上一首', 'Previous');

  String get nextLabel => L10n.tr('下一首', 'Next');

  String get windowLabel =>
      L10n.tr('显示/隐藏主窗口', 'Show/Hide Window');

  String get quitLabel => L10n.tr('退出', 'Quit');

  /// Track-dependent commands are disabled until a queue item exists.
  bool get mediaEnabled => hasTrack;
}
