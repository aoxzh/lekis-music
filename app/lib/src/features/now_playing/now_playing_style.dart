// 正在播放页视觉样式：封面（默认）/ 黑胶唱片 / 磁带。
//
// 持久化在核心设置库（`ui.now_playing_style`），首帧前恢复，支持导入导出备份。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/core.dart' as core;

const String nowPlayingStyleSettingKey = 'ui.now_playing_style';

enum NowPlayingStyle {
  cover('cover'),
  vinyl('vinyl'),
  cassette('cassette');

  const NowPlayingStyle(this.storageValue);

  final String storageValue;

  static NowPlayingStyle fromStorage(String? value) => values.firstWhere(
    (s) => s.storageValue == value,
    orElse: () => NowPlayingStyle.cover,
  );
}

final nowPlayingStyleProvider =
    NotifierProvider<NowPlayingStyleNotifier, NowPlayingStyle>(
      NowPlayingStyleNotifier.new,
    );

class NowPlayingStyleNotifier extends Notifier<NowPlayingStyle> {
  @override
  NowPlayingStyle build() => NowPlayingStyle.cover;

  Future<void> set(NowPlayingStyle value) async {
    if (state == value) return;
    final previous = state;
    state = value;
    try {
      await core.setSetting(
        key: nowPlayingStyleSettingKey,
        value: value.storageValue,
      );
    } catch (_) {
      state = previous;
      rethrow;
    }
  }

  void restore(NowPlayingStyle value) => state = value;
}

Future<void> restoreNowPlayingStyle(ProviderContainer container) async {
  try {
    final raw = await core.getSetting(key: nowPlayingStyleSettingKey);
    if (raw == null) return;
    container
        .read(nowPlayingStyleProvider.notifier)
        .restore(NowPlayingStyle.fromStorage(raw));
  } catch (_) {}
}
