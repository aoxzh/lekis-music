// 歌词视图样式：设置页和播放页共用同一份持久化状态。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../settings/settings_providers.dart';
import '../settings/strings.dart';

/// 歌词舞台的排版方式。
enum LyricsStageStyle {
  flow('flow'),
  steps('steps'),
  tilt('tilt'),
  facing('facing');

  const LyricsStageStyle(this.storageValue);

  /// 写进核心设置的值。
  final String storageValue;
}

/// 歌词视图样式。经典视图是默认。
enum LyricsStyle {
  classic('classic'),
  flow('flow'),
  steps('steps'),
  tilt('tilt'),
  facing('facing');

  const LyricsStyle(this.storageValue);

  /// 写进核心设置 `ui.lyrics_stage` 的值。
  final String storageValue;

  /// 缺失或未知的值一律退回经典视图；旧版本存下的 flow / steps / tilt
  /// 继续有效。
  static LyricsStyle fromStorage(String? value) =>
      values.firstWhere((s) => s.storageValue == value, orElse: () => classic);

  /// 经典视图之外的样式由舞台渲染。
  bool get isStage => this != LyricsStyle.classic;

  /// 对应的舞台排版；经典视图返回 `null`。
  LyricsStageStyle? get stage => switch (this) {
    LyricsStyle.classic => null,
    LyricsStyle.flow => LyricsStageStyle.flow,
    LyricsStyle.steps => LyricsStageStyle.steps,
    LyricsStyle.tilt => LyricsStageStyle.tilt,
    LyricsStyle.facing => LyricsStageStyle.facing,
  };

  String get label => switch (this) {
    LyricsStyle.classic => SettingsStrings.styleClassic,
    LyricsStyle.flow => SettingsStrings.styleFlow,
    LyricsStyle.steps => SettingsStrings.styleSteps,
    LyricsStyle.tilt => SettingsStrings.styleTilt,
    LyricsStyle.facing => SettingsStrings.styleFacing,
  };

  IconData get icon => switch (this) {
    LyricsStyle.classic => Icons.lyrics_outlined,
    LyricsStyle.flow => Icons.waves_rounded,
    LyricsStyle.steps => Icons.stairs_rounded,
    LyricsStyle.tilt => Icons.format_italic_rounded,
    LyricsStyle.facing => Icons.chrome_reader_mode_outlined,
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
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final style in LyricsStyle.values)
          ChoiceChip(
            selected: style == selected,
            avatar: Icon(style.icon, size: 16),
            label: Text(style.label, overflow: TextOverflow.ellipsis),
            onSelected: (_) => onChanged(style),
          ),
      ],
    );
  }
}
