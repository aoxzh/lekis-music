import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../desktop_lyrics/desktop_lyrics_controller.dart';
import '../desktop_lyrics/desktop_lyrics_strings.dart';
import '../now_playing/lyrics_stage_settings.dart';
import '../plugins/plugins_page.dart';
import '../plugins/strings.dart';
import 'settings_categories.dart';
import 'strings.dart';
import 'usb_bit_perfect_providers.dart';
import 'widgets/settings_reveal.dart';

enum _Group {
  lyrics(SettingsCategory.appearance, '歌词 lyrics'),
  overlay(SettingsCategory.appearance, '桌面歌词 悬浮 desktop lyrics overlay'),
  playback(SettingsCategory.playback, '音频输出 audio output'),
  audio(SettingsCategory.advanced, '音频输出 audio output'),
  extensions(SettingsCategory.advanced, '插件 plugins extensions'),
  plugins(SettingsCategory.advanced, '插件 plugins extensions');

  const _Group(this.category, this.aliases);
  final SettingsCategory category;
  final String aliases;

  String? get section => switch (this) {
    _Group.lyrics => SettingsStrings.lyrics,
    _Group.overlay => DesktopLyricsStrings.title,
    _Group.audio => SettingsStrings.audioOutput,
    _Group.plugins => SettingsStrings.plugins,
    _ => null,
  };

  SettingsSearchItem item(String id, String title, String aliases) =>
      SettingsSearchItem._(this, ValueKey(id), title, aliases);
}

class SettingsSearchItem {
  const SettingsSearchItem._(this._group, this.key, this.title, this._aliases);
  final _Group _group;
  final Key key;
  final String title;
  final String _aliases;

  SettingsCategory get category => _group.category;
  bool get inPlugins => _group == _Group.plugins;
  String get path => [category.title, ?_group.section, title].join(' › ');

  Route<void> pluginRoute() => MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/plugins'),
    builder: (_) => reveal(const PluginsPage()),
  );

  Widget reveal(Widget child) =>
      SettingsReveal(target: key, request: this, child: child);
}

List<SettingsSearchItem> searchSettings(WidgetRef ref, String query) {
  final words = query.trim().toLowerCase().split(RegExp(r'\s+'));
  if (words.first.isEmpty) return const [];
  final style = ref.watch(lyricsStyleProvider);
  final lyric = _Group.lyrics.item;
  final overlay = _Group.overlay.item;
  final audio = _Group.audio.item;
  final plugin = _Group.plugins.item;
  final entries = [
    lyric(
      'lyrics.presets',
      SettingsStrings.lyricsPresets,
      '歌词舞台预设 stage presets import',
    ),
    lyric(
      'lyrics.style',
      SettingsStrings.lyricsStage,
      '歌词舞台 歌词样式 stage style classic 经典 声部 ensemble vocal parts',
    ),
    lyric(
      'settings-lyrics-font-size',
      SettingsStrings.lyricsFontSize,
      '歌词字号 歌词字体 font text size',
    ),
    lyric(
      'lyrics.translation',
      SettingsStrings.lyricsTranslation,
      '显示歌词翻译 显示译文 罗马音 show translations romanisation',
    ),
    if (style.stage != null)
      lyric('lyrics.sparks', SettingsStrings.lyricsSparks, '火花 sparks'),
    if (!style.isStage)
      lyric(
        'lyrics.ruby',
        SettingsStrings.lyricsRuby,
        '注音歌词 拼音 ruby pinyin 日文假名 振假名 kana furigana 罗马音 romaji',
      ),
    if (ref.watch(desktopLyricsSupportedProvider)) ...[
      overlay(
        'desktop-lyrics.visible',
        DesktopLyricsStrings.show,
        '显示桌面歌词 show',
      ),
      if (ref.watch(menuBarLyricsSupportedProvider))
        overlay(
          'desktop-lyrics.menu-bar-visible',
          DesktopLyricsStrings.menuBarShow,
          '显示菜单栏歌词 show menu bar',
        ),
      overlay(
        'desktop-lyrics.locked',
        DesktopLyricsStrings.locked,
        '锁定窗口 鼠标穿透 lock click-through',
      ),
      overlay(
        'desktop-lyrics.two-line',
        DesktopLyricsStrings.twoLine,
        '双行显示 two-line display',
      ),
      overlay(
        'desktop-lyrics.font-size',
        DesktopLyricsStrings.fontSize,
        '字号 font size',
      ),
      overlay(
        'desktop-lyrics.opacity',
        DesktopLyricsStrings.opacity,
        '不透明度 opacity',
      ),
    ],
    _Group.playback.item(
      'audio.device',
      SettingsStrings.outputDevice,
      '输出设备 device speaker',
    ),
    _Group.playback.item(
      'audio.normalize',
      SettingsStrings.normalize,
      '音量平衡 volume normalization ReplayGain',
    ),
    if (ref.watch(usbBitPerfectSupportedProvider))
      audio(
        'settings.usb-bit-perfect',
        SettingsStrings.usbBitPerfect,
        'USB DAC 独占 比特完美直出 bit-perfect exclusive',
      )
    else
      audio(
        'audio.mode',
        SettingsStrings.outputMode,
        '输出模式 共享 独占 mode shared exclusive bit-perfect',
      ),
    audio(
      'audio.replaygain',
      SettingsStrings.replayGain,
      'ReplayGain 模式 响度 音量增益 mode album track',
    ),
    _Group.extensions.item(
      'plugins.entry',
      SettingsStrings.plugins,
      '管理 manager',
    ),
    plugin(
      'plugins.install',
      PluginStrings.install,
      '安装插件 install zip link 文件夹 链接',
    ),
    plugin(
      'plugins.browse',
      PluginStrings.browse,
      '浏览插件目录 catalog registry browse',
    ),
    plugin(
      'plugins.directory',
      PluginStrings.pluginDir,
      '插件目录 folder directory',
    ),
    plugin('plugins.refresh', PluginStrings.refresh, '刷新 refresh'),
  ];
  return [
    for (final entry in entries)
      if (words.every(
        '${entry.path} ${entry._group.aliases} ${entry._aliases}'
            .toLowerCase()
            .contains,
      ))
        entry,
  ];
}

class SettingsSearchRow extends StatelessWidget {
  const SettingsSearchRow({super.key, required this.item, required this.onTap});
  final SettingsSearchItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      ListTile(dense: true, title: Text(item.path), onTap: onTap);
}
