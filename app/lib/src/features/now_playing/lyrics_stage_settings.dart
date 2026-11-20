// 歌词视图样式：设置页和播放页共用同一份持久化状态。
//
// 核心设置 `ui.lyrics_stage` 里存 `classic`（默认）/ `flow` / `steps` /
// `tilt`。经典视图是 Apple Music 那样的逐行滚动歌词；另外三种是逐字
// 跟唱的「歌词舞台」。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../settings/settings_providers.dart';
import '../settings/strings.dart';

/// 歌词舞台的排版方式（经典视图之外的三选一）。
enum LyricsStageStyle {
  flow('flow'),
  steps('steps'),
  tilt('tilt');

  const LyricsStageStyle(this.storageValue);

  /// 写进核心设置的值。
  final String storageValue;
}

/// 歌词视图样式。经典视图是默认，另外三种由舞台渲染。
enum LyricsStyle {
  classic('classic'),
  flow('flow'),
  steps('steps'),
  tilt('tilt');

  const LyricsStyle(this.storageValue);

  /// 写进核心设置 `ui.lyrics_stage` 的值。
  final String storageValue;

  /// 缺失或未知的值一律退回经典视图；旧版本存下的 flow / steps / tilt
  /// 继续有效。
  static LyricsStyle fromStorage(String? value) =>
      values.firstWhere((s) => s.storageValue == value, orElse: () => classic);

  /// 经典视图之外的三种样式由舞台渲染。
  bool get isStage => this != LyricsStyle.classic;

  /// 对应的舞台排版；经典视图返回 `null`。
  LyricsStageStyle? get stage => switch (this) {
    LyricsStyle.classic => null,
    LyricsStyle.flow => LyricsStageStyle.flow,
    LyricsStyle.steps => LyricsStageStyle.steps,
    LyricsStyle.tilt => LyricsStageStyle.tilt,
  };

  String get label => switch (this) {
    LyricsStyle.classic => SettingsStrings.styleClassic,
    LyricsStyle.flow => SettingsStrings.styleFlow,
    LyricsStyle.steps => SettingsStrings.styleSteps,
    LyricsStyle.tilt => SettingsStrings.styleTilt,
  };

  IconData get icon => switch (this) {
    LyricsStyle.classic => Icons.lyrics_outlined,
    LyricsStyle.flow => Icons.waves_rounded,
    LyricsStyle.steps => Icons.stairs_rounded,
    LyricsStyle.tilt => Icons.format_italic_rounded,
  };
}

/// 当前歌词视图样式；核心还没返回时按经典视图渲染。
final lyricsStyleProvider = Provider<LyricsStyle>((ref) {
  final value = ref.watch(settingProvider(SettingKeys.lyricsStage)).value;
  return LyricsStyle.fromStorage(value);
});

/// 是否显示逐字火花；缺省开启。只对舞台样式有效。
final lyricsSparksProvider = Provider<bool>((ref) {
  final value = ref.watch(settingProvider(SettingKeys.lyricsSparks)).value;
  return value != 'false';
});

/// 纯展示控件，方便设置页直接使用，也方便单独测试选择回调。
class LyricsStyleSelector extends StatelessWidget {
  const LyricsStyleSelector({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final LyricsStyle selected;
  final ValueChanged<LyricsStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<LyricsStyle>(
      showSelectedIcon: false,
      segments: [
        for (final style in LyricsStyle.values)
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
