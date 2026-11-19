// 歌词舞台的样式选择：设置页和播放页共用同一份持久化状态。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../settings/settings_providers.dart';
import '../settings/strings.dart';

/// 三种舞台排版。值写进核心设置 `ui.lyrics_stage`。
enum LyricsStageStyle {
  flow('flow'),
  steps('steps'),
  tilt('tilt');

  const LyricsStageStyle(this.storageValue);
  final String storageValue;

  static LyricsStageStyle fromStorage(String? value) =>
      values.firstWhere((s) => s.storageValue == value, orElse: () => flow);

  String get label => switch (this) {
    LyricsStageStyle.flow => SettingsStrings.styleFlow,
    LyricsStageStyle.steps => SettingsStrings.styleSteps,
    LyricsStageStyle.tilt => SettingsStrings.styleTilt,
  };

  IconData get icon => switch (this) {
    LyricsStageStyle.flow => Icons.waves_rounded,
    LyricsStageStyle.steps => Icons.stairs_rounded,
    LyricsStageStyle.tilt => Icons.format_italic_rounded,
  };
}

/// 当前舞台样式；核心还没返回时默认流动。
final lyricsStageStyleProvider = Provider<LyricsStageStyle>((ref) {
  final value = ref.watch(settingProvider(SettingKeys.lyricsStage)).value;
  return LyricsStageStyle.fromStorage(value);
});

/// 是否显示逐字火花；缺省开启。
final lyricsSparksProvider = Provider<bool>((ref) {
  final value = ref.watch(settingProvider(SettingKeys.lyricsSparks)).value;
  return value != 'false';
});

/// 纯展示控件，方便设置页直接使用，也方便单独测试选择回调。
class LyricsStageStyleSelector extends StatelessWidget {
  const LyricsStageStyleSelector({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final LyricsStageStyle selected;
  final ValueChanged<LyricsStageStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<LyricsStageStyle>(
      showSelectedIcon: false,
      segments: [
        for (final style in LyricsStageStyle.values)
          ButtonSegment(
            value: style,
            label: Text(style.label),
            icon: Icon(style.icon),
          ),
      ],
      selected: {selected},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}
