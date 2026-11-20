// 设置的二级页面：整理资料库、播放、外观、歌词、高级、关于。
//
// 每个分类只给出若干 [SettingsSection]；手机上包成推入的子页面，
// 宽窗口里直接放进右栏（见 settings_page.dart）。

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../platform/ui_profile.dart';
import '../../rust/api/dto.dart';
import '../../shell/app_shell.dart';
import '../../shell/tab_bar_style.dart';
import '../../theme/tokens.dart';
import '../enrich/enrich_providers.dart';
import '../library/library_health_page.dart';
import '../now_playing/lyrics_stage_settings.dart';
import '../player/sleep_timer.dart';
import '../plugins/plugins_providers.dart';
import '../sources/common.dart';
import 'desktop_tray_settings_section.dart';
import 'equalizer_page.dart';
import 'logs_page.dart';
import 'scrobble_page.dart';
import 'settings_backup.dart';
import 'settings_guard.dart';
import 'settings_providers.dart';
import '../connect/connect_strings.dart';
import 'connect_settings_section.dart';
import 'strings.dart';
import 'tab_bar_style_picker.dart';
import 'theme_preference.dart';
import 'widgets/settings_widgets.dart';

/// 设置首页（手机）/ 左侧导航（桌面）里的分组，按这个顺序排列。
enum SettingsCategoryGroup {
  music(SettingsStrings.groupMusic),
  general(SettingsStrings.groupGeneral),
  more(SettingsStrings.groupMore);

  const SettingsCategoryGroup(this.title);
  final String title;
}

/// 顶层列表里可以进入的二级分类。
///
/// **加一个分类只要在这里加一行**（例如多设备同步）：
///
/// ```dart
/// sync(SettingsStrings.sync, SettingsStrings.syncHint, Icons.devices_rounded,
///     SettingsCategoryGroup.music, _syncSections),
/// ```
///
/// 再写一个返回若干 [SettingsSection] 的顶层函数 `_syncSections`。手机首页、
/// 桌面左侧导航、桌面搜索（标题 + 说明 + [keywords]）都会自动带上它；
/// 同一分组内按这里的声明顺序排列。
enum SettingsCategory {
  organize(
    SettingsStrings.organize,
    SettingsStrings.organizeHint,
    Icons.health_and_safety_outlined,
    SettingsCategoryGroup.music,
    _organizeSections,
    keywords: [SettingsStrings.libraryHealth, SettingsStrings.enrichReview],
  ),
  connect(
    ConnectStrings.title,
    ConnectStrings.nearbyHint,
    Icons.devices_rounded,
    SettingsCategoryGroup.general,
    _connectSections,
    keywords: [
      ConnectStrings.nearby,
      ConnectStrings.allowControl,
      ConnectStrings.playHere,
      ConnectStrings.remote,
    ],
  ),
  playback(
    SettingsStrings.playback,
    SettingsStrings.playbackHint,
    Icons.play_circle_outline_rounded,
    SettingsCategoryGroup.general,
    _playbackSections,
    keywords: [
      SettingsStrings.outputDevice,
      SettingsStrings.gapless,
      SettingsStrings.normalize,
      SettingsStrings.sleepTimer,
      EqualizerStrings.title,
    ],
  ),
  appearance(
    SettingsStrings.appearance,
    SettingsStrings.appearanceHint,
    Icons.palette_outlined,
    SettingsCategoryGroup.general,
    _appearanceSections,
    desktopHint: SettingsStrings.appearanceHintDesktop,
    keywords: [
      SettingsStrings.theme,
      SettingsStrings.themeDark,
      SettingsStrings.themeLight,
    ],
  ),
  lyrics(
    SettingsStrings.lyrics,
    SettingsStrings.lyricsHint,
    Icons.lyrics_outlined,
    SettingsCategoryGroup.general,
    _lyricsSections,
    keywords: [SettingsStrings.lyricsStage, SettingsStrings.lyricsSparks],
  ),
  advanced(
    SettingsStrings.advanced,
    SettingsStrings.advancedHint,
    Icons.tune_rounded,
    SettingsCategoryGroup.more,
    _advancedSections,
    keywords: [
      SettingsStrings.outputMode,
      SettingsStrings.replayGain,
      SettingsStrings.scrobbling,
      SettingsStrings.plugins,
      SettingsStrings.desktopTrayEnabled,
      SettingsStrings.backup,
      SettingsStrings.diagnosticLogs,
    ],
  ),
  about(
    SettingsStrings.about,
    SettingsStrings.aboutHint,
    Icons.info_outline_rounded,
    SettingsCategoryGroup.more,
    _aboutSections,
    keywords: [SettingsStrings.coreVersion, SettingsStrings.deviceId],
  );

  const SettingsCategory(
    this.title,
    this._hint,
    this.icon,
    this.group,
    this._sections, {
    this.keywords = const [],
    this.desktopHint,
  });

  final String title;
  final String _hint;
  final IconData icon;
  final SettingsCategoryGroup group;
  final List<Widget> Function() _sections;

  /// Extra words the desktop settings search matches (row titles).
  final List<String> keywords;

  /// Replaces [hint] on desktop when the mobile one names options that are
  /// hidden there (e.g. the tab bar style).
  final String? desktopHint;

  /// One-line summary under the title.
  String get hint =>
      UiProfile.current.isDesktop ? (desktopHint ?? _hint) : _hint;

  /// 这个分类的内容（若干分组）。
  List<Widget> get sections => _sections();

  /// The categories of [group], in declaration order.
  static List<SettingsCategory> inGroup(SettingsCategoryGroup group) =>
      values.where((c) => c.group == group).toList(growable: false);

  /// Whether [query] (already lower-cased) matches this category.
  bool matches(String query) =>
      query.isEmpty ||
      [title, hint, ...keywords].any((s) => s.toLowerCase().contains(query));
}

List<Widget> _organizeSections() => const [_OrganizeSection()];
List<Widget> _connectSections() => const [ConnectSettingsSection()];
List<Widget> _playbackSections() => const [_PlaybackSection()];
List<Widget> _appearanceSections() => const [_AppearanceSection()];
List<Widget> _lyricsSections() => const [_LyricsSection()];
List<Widget> _advancedSections() => [
  const _AudioOutputSection(),
  const _ServicesSection(),
  if (DesktopTraySettingsSection.isSupported)
    const DesktopTraySettingsSection(),
  const SettingsBackupSection(),
  const _DiagnosticsSection(),
];
List<Widget> _aboutSections() => const [_AboutSection()];

/// 手机 / 窄窗口里推入的二级页面。
class SettingsCategoryPage extends StatelessWidget {
  const SettingsCategoryPage({super.key, required this.category});

  final SettingsCategory category;

  static Route<void> route(SettingsCategory category) =>
      MaterialPageRoute<void>(
        builder: (_) => SettingsCategoryPage(category: category),
      );

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: category.title,
    body: SettingsListView(children: category.sections),
  );
}

// ---------------------------------------------------------------------------
// 整理资料库
// ---------------------------------------------------------------------------

class _OrganizeSection extends ConsumerWidget {
  const _OrganizeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(enrichPendingCountProvider);
    return SettingsSection(
      title: SettingsStrings.organize,
      children: [
        SettingsTile(
          icon: Icons.health_and_safety_outlined,
          title: SettingsStrings.libraryHealth,
          subtitle: const Text(SettingsStrings.libraryHealthHint),
          chevron: true,
          onTap: () => Navigator.of(context).push(LibraryHealthPage.route()),
        ),
        SettingsTile(
          icon: Icons.auto_fix_high_outlined,
          title: SettingsStrings.enrichReview,
          subtitle: Text(
            pending != null && pending > 0
                ? SettingsStrings.pendingCount(pending)
                : SettingsStrings.enrichReviewHint,
          ),
          trailing: pending != null && pending > 0
              ? Badge.count(count: pending)
              : null,
          chevron: true,
          onTap: () => openEnrichReview(context),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 播放：普通用户会碰的几项
// ---------------------------------------------------------------------------

class _PlaybackSection extends ConsumerWidget {
  const _PlaybackSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(playbackOutputProvider);
    final notifier = ref.read(playbackOutputProvider.notifier);
    final gapless = ref.watch(settingProvider(SettingKeys.gapless));
    final replayGain = ref.watch(settingProvider(SettingKeys.replayGain));
    final rgMode = ReplayGainMode.fromStorage(replayGain.value);
    final colors = context.lekisColors;
    final text = Theme.of(context).textTheme;
    final error = output.error;

    final desktop = UiProfile.current.desktopSettings;
    final sleep = ref.watch(sleepTimerProvider).kind;

    return SettingsSection(
      title: SettingsStrings.playback,
      children: [
        if (desktop && error == null && output.devices.isNotEmpty)
          SettingsDropdownTile<String?>(
            icon: Icons.speaker_outlined,
            title: SettingsStrings.outputDevice,
            value: output.selectedDeviceId,
            leading: [
              IconButton(
                tooltip: SettingsStrings.refreshDevices,
                onPressed: notifier.refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
              const SizedBox(width: LekisSpacing.xs),
            ],
            choices: [
              const SettingsChoice<String?>(
                null,
                SettingsStrings.systemDefault,
              ),
              for (final d in output.devices)
                SettingsChoice<String?>(
                  d.id,
                  d.isDefault ? SettingsStrings.defaultSuffix(d.name) : d.name,
                ),
            ],
            onChanged: (id) =>
                settingsGuard(context, () => notifier.selectDevice(id)),
          )
        else
          SettingsBlockTile(
            icon: Icons.speaker_outlined,
            title: SettingsStrings.outputDevice,
            trailing: IconButton(
              tooltip: SettingsStrings.refreshDevices,
              onPressed: notifier.refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
            child: error != null
                ? Text(
                    describeCoreError(error),
                    style: text.bodySmall?.copyWith(color: colors.danger),
                  )
                : output.devices.isEmpty
                ? Text(SettingsStrings.noDevices, style: text.bodySmall)
                : DropdownButton<String?>(
                    value: output.selectedDeviceId,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    borderRadius: BorderRadius.circular(LekisRadius.md),
                    onChanged: (id) =>
                        settingsGuard(context, () => notifier.selectDevice(id)),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text(SettingsStrings.systemDefault),
                      ),
                      for (final d in output.devices)
                        DropdownMenuItem<String?>(
                          value: d.id,
                          child: Text(
                            d.isDefault
                                ? SettingsStrings.defaultSuffix(d.name)
                                : d.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
          ),
        SettingsSwitchTile(
          icon: Icons.linear_scale_rounded,
          title: SettingsStrings.gapless,
          subtitle: SettingsStrings.gaplessHint,
          value: gapless.value != 'false',
          onChanged: gapless.isLoading
              ? null
              : (v) => settingsGuard(
                  context,
                  () => ref
                      .read(settingProvider(SettingKeys.gapless).notifier)
                      .set(v ? 'true' : 'false'),
                ),
        ),
        // 简单开关；按曲目 / 按专辑的细节在“高级”里。
        SettingsSwitchTile(
          icon: Icons.equalizer_rounded,
          title: SettingsStrings.normalize,
          subtitle: SettingsStrings.normalizeHint,
          value: rgMode != ReplayGainMode.off,
          onChanged: replayGain.isLoading
              ? null
              : (v) => settingsGuard(
                  context,
                  () => ref
                      .read(settingProvider(SettingKeys.replayGain).notifier)
                      .set(
                        (v ? ReplayGainMode.track : ReplayGainMode.off)
                            .storageValue,
                      ),
                ),
        ),
        SettingsTile(
          icon: Icons.graphic_eq_rounded,
          title: EqualizerStrings.title,
          subtitle: const Text(EqualizerStrings.entryHint),
          chevron: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const EqualizerPage()),
          ),
        ),
        if (desktop)
          SettingsDropdownTile<SleepTimerKind>(
            icon: Icons.bedtime_outlined,
            title: SettingsStrings.sleepTimer,
            subtitle: SettingsStrings.sleepTimerHint,
            value: sleep,
            choices: [
              for (final kind in SleepTimerKind.values)
                SettingsChoice(kind, kind.label),
            ],
            onChanged: (kind) =>
                ref.read(sleepTimerProvider.notifier).set(kind),
          )
        else
          SettingsBlockTile(
            icon: Icons.bedtime_outlined,
            title: SettingsStrings.sleepTimer,
            hint: SettingsStrings.sleepTimerHint,
            child: Wrap(
              spacing: LekisSpacing.sm,
              runSpacing: LekisSpacing.xs,
              children: [
                for (final kind in SleepTimerKind.values)
                  ChoiceChip(
                    label: Text(kind.label),
                    selected: sleep == kind,
                    onSelected: (_) =>
                        ref.read(sleepTimerProvider.notifier).set(kind),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 外观
// ---------------------------------------------------------------------------

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pref = ref.watch(themePreferenceProvider);
    final tabBarStyle = ref.watch(tabBarStyleProvider);
    final profile = UiProfile.current;
    void setTheme(ThemePreference p) =>
        settingsGuard(context, () => setThemePreference(ref, p));
    return SettingsSection(
      title: SettingsStrings.appearance,
      children: [
        if (profile.desktopSettings)
          SettingsDropdownTile<ThemePreference>(
            key: const ValueKey('settings-theme'),
            icon: Icons.palette_outlined,
            title: SettingsStrings.theme,
            value: pref,
            choices: const [
              SettingsChoice(
                ThemePreference.system,
                SettingsStrings.themeSystem,
              ),
              SettingsChoice(ThemePreference.light, SettingsStrings.themeLight),
              SettingsChoice(ThemePreference.dark, SettingsStrings.themeDark),
              SettingsChoice(
                ThemePreference.oledBlack,
                SettingsStrings.themeOled,
              ),
            ],
            onChanged: setTheme,
          )
        else
          SettingsBlockTile(
            icon: Icons.palette_outlined,
            title: SettingsStrings.theme,
            hint: SettingsStrings.themeOledHint,
            child: SegmentedButton<ThemePreference>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: ThemePreference.system,
                  label: Text(SettingsStrings.themeSystem),
                  icon: Icon(Icons.brightness_auto_outlined),
                ),
                ButtonSegment(
                  value: ThemePreference.light,
                  label: Text(SettingsStrings.themeLight),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: ThemePreference.dark,
                  label: Text(SettingsStrings.themeDark),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
                ButtonSegment(
                  value: ThemePreference.oledBlack,
                  label: Text(SettingsStrings.themeOled),
                  icon: Icon(Icons.contrast),
                ),
              ],
              selected: {pref},
              onSelectionChanged: (s) => setTheme(s.first),
            ),
          ),
        // Liquid glass vs flat only exists where the glass tab bar does;
        // desktop always draws flat chrome, so the choice is not offered.
        if (profile.offersTabBarStyle)
          SettingsBlockTile(
            icon: Icons.space_dashboard_outlined,
            title: SettingsStrings.tabBarStyle,
            hint: SettingsStrings.tabBarStyleHint,
            child: TabBarStylePicker(
              selected: tabBarStyle,
              onChanged: (style) => settingsGuard(
                context,
                () => ref.read(tabBarStyleProvider.notifier).set(style),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 歌词（样式选择器归正在播放模块所有，这里原样使用）
// ---------------------------------------------------------------------------

class _LyricsSection extends ConsumerWidget {
  const _LyricsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsStyle = ref.watch(lyricsStyleProvider);
    final sparks = ref.watch(lyricsSparksProvider);
    void setStyle(LyricsStyle next) => settingsGuard(
      context,
      () => ref
          .read(settingProvider(SettingKeys.lyricsStage).notifier)
          .set(next.storageValue),
    );
    return SettingsSection(
      title: SettingsStrings.lyrics,
      children: [
        if (UiProfile.current.desktopSettings)
          SettingsDropdownTile<LyricsStyle>(
            icon: Icons.lyrics_outlined,
            title: SettingsStrings.lyricsStage,
            subtitle: SettingsStrings.lyricsStageHint,
            value: lyricsStyle,
            choices: [
              for (final style in LyricsStyle.values)
                SettingsChoice(style, style.label),
            ],
            onChanged: setStyle,
          )
        else
          SettingsBlockTile(
            icon: Icons.lyrics_outlined,
            title: SettingsStrings.lyricsStage,
            hint: SettingsStrings.lyricsStageHint,
            child: LyricsStyleSelector(
              selected: lyricsStyle,
              onChanged: setStyle,
            ),
          ),
        // 火花只对逐字舞台有意义，经典视图下不显示这个开关。
        if (lyricsStyle.isStage)
          SettingsSwitchTile(
            icon: Icons.auto_awesome_outlined,
            title: SettingsStrings.lyricsSparks,
            subtitle: SettingsStrings.lyricsSparksHint,
            value: sparks,
            onChanged: (on) => settingsGuard(
              context,
              () => ref
                  .read(settingProvider(SettingKeys.lyricsSparks).notifier)
                  .set(on ? 'true' : 'false'),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 高级：独占输出、ReplayGain 细节、听歌记录、插件、托盘、备份、日志
// ---------------------------------------------------------------------------

class _AudioOutputSection extends ConsumerWidget {
  const _AudioOutputSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(playbackOutputProvider);
    final notifier = ref.read(playbackOutputProvider.notifier);
    final replayGain = ReplayGainMode.fromStorage(
      ref.watch(settingProvider(SettingKeys.replayGain)).value,
    );
    if (UiProfile.current.desktopSettings) {
      return SettingsSection(
        title: SettingsStrings.audioOutput,
        children: [
          SettingsDropdownTile<OutputModeDto>(
            icon: Icons.graphic_eq_rounded,
            title: SettingsStrings.outputMode,
            subtitle: output.mode == OutputModeDto.exclusive
                ? SettingsStrings.modeExclusiveHint
                : output.exclusiveSupported
                ? SettingsStrings.modeSharedHint
                : '${SettingsStrings.modeSharedHint}${SettingsStrings.exclusiveUnsupported}。',
            value: output.mode,
            choices: [
              const SettingsChoice(
                OutputModeDto.shared,
                SettingsStrings.modeShared,
              ),
              SettingsChoice(
                OutputModeDto.exclusive,
                SettingsStrings.modeExclusive,
                enabled: output.exclusiveSupported,
              ),
            ],
            onChanged: (m) => settingsGuard(context, () => notifier.setMode(m)),
          ),
          SettingsDropdownTile<ReplayGainMode>(
            icon: Icons.equalizer_rounded,
            title: SettingsStrings.replayGain,
            subtitle: SettingsStrings.replayGainHint,
            value: replayGain,
            choices: const [
              SettingsChoice(ReplayGainMode.track, SettingsStrings.rgTrack),
              SettingsChoice(ReplayGainMode.album, SettingsStrings.rgAlbum),
              SettingsChoice(ReplayGainMode.off, SettingsStrings.rgOff),
            ],
            onChanged: (m) => settingsGuard(
              context,
              () => ref
                  .read(settingProvider(SettingKeys.replayGain).notifier)
                  .set(m.storageValue),
            ),
          ),
        ],
      );
    }
    return SettingsSection(
      title: SettingsStrings.audioOutput,
      children: [
        SettingsBlockTile(
          icon: Icons.graphic_eq_rounded,
          title: SettingsStrings.outputMode,
          hint: output.mode == OutputModeDto.exclusive
              ? SettingsStrings.modeExclusiveHint
              : output.exclusiveSupported
              ? '${SettingsStrings.modeSharedHint}\n${SettingsStrings.modeExclusiveHint}'
              : '${SettingsStrings.modeSharedHint}\n${SettingsStrings.exclusiveUnsupported}',
          child: SegmentedButton<OutputModeDto>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(
                value: OutputModeDto.shared,
                label: Text(SettingsStrings.modeShared),
                icon: Icon(Icons.speaker_group_outlined),
              ),
              ButtonSegment(
                value: OutputModeDto.exclusive,
                label: const Text(SettingsStrings.modeExclusive),
                icon: const Icon(Icons.graphic_eq),
                enabled: output.exclusiveSupported,
              ),
            ],
            selected: {output.mode},
            onSelectionChanged: (s) =>
                settingsGuard(context, () => notifier.setMode(s.first)),
          ),
        ),
        SettingsBlockTile(
          icon: Icons.equalizer_rounded,
          title: SettingsStrings.replayGain,
          hint: SettingsStrings.replayGainHint,
          child: SegmentedButton<ReplayGainMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: ReplayGainMode.track,
                label: Text(SettingsStrings.rgTrack),
              ),
              ButtonSegment(
                value: ReplayGainMode.album,
                label: Text(SettingsStrings.rgAlbum),
              ),
              ButtonSegment(
                value: ReplayGainMode.off,
                label: Text(SettingsStrings.rgOff),
              ),
            ],
            selected: {replayGain},
            onSelectionChanged: (s) => settingsGuard(
              context,
              () => ref
                  .read(settingProvider(SettingKeys.replayGain).notifier)
                  .set(s.first.storageValue),
            ),
          ),
        ),
      ],
    );
  }
}

class _ServicesSection extends StatelessWidget {
  const _ServicesSection();

  @override
  Widget build(BuildContext context) => const SettingsSection(
    title: SettingsStrings.servicesGroup,
    children: [ScrobbleSettingsTile(), PluginsSettingsTile()],
  );
}

/// 插件入口。放在这里方便单独测试列表摘要状态。
class PluginsSettingsTile extends ConsumerWidget {
  const PluginsSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref.watch(pluginListProvider);
    final count = plugins.value?.length;
    final subtitle = plugins.hasError
        ? SettingsStrings.pluginLoadFailed
        : count == null
        ? SettingsStrings.unavailable
        : count == 0
        ? SettingsStrings.pluginsEmpty
        : SettingsStrings.pluginsInstalled(count);
    return SettingsTile(
      icon: Icons.extension_outlined,
      title: SettingsStrings.plugins,
      subtitle: Text(subtitle),
      chevron: true,
      onTap: () => openPlugins(context),
    );
  }
}

class _DiagnosticsSection extends StatelessWidget {
  const _DiagnosticsSection();

  @override
  Widget build(BuildContext context) => SettingsSection(
    title: SettingsStrings.diagnostics,
    children: [
      SettingsTile(
        icon: Icons.receipt_long_outlined,
        title: SettingsStrings.diagnosticLogs,
        subtitle: const Text(SettingsStrings.diagnosticLogsHint),
        chevron: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const DiagnosticLogsPage()),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// 关于
// ---------------------------------------------------------------------------

class _AboutSection extends ConsumerWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(aboutInfoProvider);
    final deviceId = info.deviceId;
    return SettingsSection(
      title: SettingsStrings.about,
      children: [
        SettingsTile(
          icon: Icons.memory_outlined,
          title: SettingsStrings.coreVersion,
          trailing: Text(info.coreVersion ?? SettingsStrings.unavailable),
        ),
        SettingsTile(
          icon: Icons.fingerprint_rounded,
          title: SettingsStrings.deviceId,
          subtitle: SelectableText(deviceId ?? SettingsStrings.unavailable),
          trailing: deviceId == null
              ? null
              : IconButton(
                  tooltip: SettingsStrings.copy,
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: deviceId));
                    if (context.mounted) {
                      showFeatureSnack(context, SettingsStrings.copied);
                    }
                  },
                ),
        ),
      ],
    );
  }
}
