// 设置 > 歌词 > 桌面悬浮歌词（UIX-07，仅支持的桌面端显示）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../widgets/lekis_slider.dart';
import '../settings/widgets/settings_widgets.dart';
import 'desktop_lyrics_controller.dart';
import 'desktop_lyrics_strings.dart';

class DesktopLyricsSettingsSection extends ConsumerWidget {
  const DesktopLyricsSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(desktopLyricsSupportedProvider)) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(desktopLyricsProvider);
    final ctrl = ref.read(desktopLyricsProvider.notifier);

    return SettingsSection(
      title: DesktopLyricsStrings.title,
      children: [
        if (ref.watch(menuBarLyricsSupportedProvider))
          SettingsSwitchTile(
            key: const ValueKey('desktop-lyrics.menu-bar-visible'),
            icon: Icons.short_text_rounded,
            title: DesktopLyricsStrings.menuBarShow,
            subtitle: DesktopLyricsStrings.menuBarHint,
            value: state.menuBarVisible,
            onChanged: ctrl.setMenuBarVisible,
          ),
        SettingsSwitchTile(
          key: const ValueKey('desktop-lyrics.visible'),
          icon: Icons.subtitles_outlined,
          title: DesktopLyricsStrings.show,
          subtitle: DesktopLyricsStrings.showHint,
          value: state.visible,
          onChanged: ctrl.setVisible,
        ),
        SettingsSwitchTile(
          key: const ValueKey('desktop-lyrics.locked'),
          icon: Icons.lock_outline_rounded,
          title: DesktopLyricsStrings.locked,
          subtitle: DesktopLyricsStrings.lockedHint,
          value: state.locked,
          onChanged: ctrl.setLocked,
        ),
        SettingsSwitchTile(
          key: const ValueKey('desktop-lyrics.two-line'),
          icon: Icons.view_agenda_outlined,
          title: DesktopLyricsStrings.twoLine,
          subtitle: DesktopLyricsStrings.twoLineHint,
          value: state.twoLine,
          onChanged: ctrl.setTwoLine,
        ),
        SettingsBlockTile(
          icon: Icons.format_size_rounded,
          title: '${DesktopLyricsStrings.fontSize}（${state.fontSize.round()}）',
          child: LekisSlider(
            key: const ValueKey('desktop-lyrics.font-size'),
            semanticLabel: DesktopLyricsStrings.fontSize,
            min: 18,
            max: 60,
            divisions: 21,
            value: state.fontSize,
            onChanged: (v) => ctrl.setFontSize(v, persist: false),
            onChangeEnd: (v) => ctrl.setFontSize(v, persist: true),
          ),
        ),
        SettingsBlockTile(
          icon: Icons.opacity_rounded,
          title:
              '${DesktopLyricsStrings.opacity}（${(state.opacity * 100).round()}%）',
          child: LekisSlider(
            key: const ValueKey('desktop-lyrics.opacity'),
            semanticLabel: DesktopLyricsStrings.opacity,
            min: 0.4,
            max: 1.0,
            divisions: 12,
            value: state.opacity,
            onChanged: (v) => ctrl.setOpacity(v, persist: false),
            onChangeEnd: (v) => ctrl.setOpacity(v, persist: true),
          ),
        ),
      ],
    );
  }
}
