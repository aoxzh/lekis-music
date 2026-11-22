// 设置的二级页面：整理资料库、多设备同步、在其他设备上播放、播放、外观（含歌词）、高级、关于。
//
// 每个分类只给出若干 [SettingsSection]；手机上包成推入的子页面，
// 宽窗口里直接放进右栏（见 settings_page.dart）。

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../l10n/app_locale.dart';
import '../../platform/external_url.dart';
import '../../platform/ui_profile.dart';
import '../../rust/api/dto.dart';
import '../../shell/app_shell.dart';
import '../../shell/nav_bar_position.dart';
import '../../shell/tab_bar_style.dart';
import '../../theme/tokens.dart';
import '../enrich/enrich_providers.dart';
import '../library/library_health_page.dart';
import '../now_playing/lyrics_stage_settings.dart';
import '../now_playing/now_playing_style.dart';
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
import '../desktop_lyrics/desktop_lyrics_settings_section.dart';
import '../desktop_lyrics/desktop_lyrics_strings.dart';
import '../sync/sync_settings_section.dart';
import '../sync/sync_strings.dart';
import 'app_updater.dart';
import 'connect_settings_section.dart';
import 'strings.dart';
import 'tab_bar_style_picker.dart';
import 'theme_preference.dart';
import 'usb_bit_perfect_settings.dart';
import 'widgets/settings_widgets.dart';

/// 设置首页（手机）/ 左侧导航（桌面）里的分组，按这个顺序排列。
enum SettingsCategoryGroup {
  music,
  general,
  more;

  String get title => switch (this) {
    SettingsCategoryGroup.music => SettingsStrings.groupMusic,
    SettingsCategoryGroup.general => SettingsStrings.groupGeneral,
    SettingsCategoryGroup.more => SettingsStrings.groupMore,
  };

  String titleOf(BuildContext context) {
    context.l10n;
    return title;
  }
}

/// 顶层列表里可以进入的二级分类。
enum SettingsCategory {
  organize(
    Icons.health_and_safety_outlined,
    SettingsCategoryGroup.music,
    _organizeSections,
  ),
  sync(
    Icons.sync_rounded,
    SettingsCategoryGroup.music,
    buildSyncSettingsSections,
  ),
  connect(
    Icons.devices_rounded,
    SettingsCategoryGroup.general,
    _connectSections,
  ),
  playback(
    Icons.play_circle_outline_rounded,
    SettingsCategoryGroup.general,
    _playbackSections,
  ),
  appearance(
    Icons.palette_outlined,
    SettingsCategoryGroup.general,
    _appearanceSections,
  ),
  advanced(
    Icons.tune_rounded,
    SettingsCategoryGroup.more,
    _advancedSections,
  ),
  about(
    Icons.info_outline_rounded,
    SettingsCategoryGroup.more,
    _aboutSections,
  );

  const SettingsCategory(this.icon, this.group, this._sections);

  final IconData icon;
  final SettingsCategoryGroup group;
  final List<Widget> Function() _sections;

  String get title => switch (this) {
    SettingsCategory.organize => SettingsStrings.organize,
    SettingsCategory.sync => SyncStrings.title,
    SettingsCategory.connect => ConnectStrings.title,
    SettingsCategory.playback => SettingsStrings.playback,
    SettingsCategory.appearance => SettingsStrings.appearance,
    SettingsCategory.advanced => SettingsStrings.advanced,
    SettingsCategory.about => SettingsStrings.about,
  };

  String get hint => switch (this) {
    SettingsCategory.organize => SettingsStrings.organizeHint,
    SettingsCategory.sync => SyncStrings.hint,
    SettingsCategory.connect => ConnectStrings.nearbyHint,
    SettingsCategory.playback => SettingsStrings.playbackHint,
    SettingsCategory.appearance =>
      UiProfile.current.isDesktop
          ? SettingsStrings.appearanceHintDesktop
          : SettingsStrings.appearanceHint,
    SettingsCategory.advanced => SettingsStrings.advancedHint,
    SettingsCategory.about => SettingsStrings.aboutHint,
  };

  List<String> get keywords => switch (this) {
    SettingsCategory.organize => [
      SettingsStrings.libraryHealth,
      SettingsStrings.enrichReview,
    ],
    SettingsCategory.sync => [
      SyncStrings.sectionChannel,
      SyncStrings.syncNow,
      SyncStrings.autoOnLaunch,
    ],
    SettingsCategory.connect => [
      ConnectStrings.nearby,
      ConnectStrings.allowControl,
      ConnectStrings.playHere,
      ConnectStrings.remote,
    ],
    SettingsCategory.playback => [
      SettingsStrings.outputDevice,
      SettingsStrings.gapless,
      SettingsStrings.normalize,
      SettingsStrings.sleepTimer,
      EqualizerStrings.title,
    ],
    SettingsCategory.appearance => [
      SettingsStrings.theme,
      SettingsStrings.themeDark,
      SettingsStrings.themeLight,
      SettingsStrings.language,
      SettingsStrings.nowPlayingStyle,
      SettingsStrings.nowPlayingVinyl,
      SettingsStrings.nowPlayingCassette,
      SettingsStrings.tabBarStyle,
      SettingsStrings.navBarPosition,
      SettingsStrings.lyrics,
      SettingsStrings.lyricsStage,
      SettingsStrings.lyricsSparks,
      DesktopLyricsStrings.title,
    ],
    SettingsCategory.advanced => [
      SettingsStrings.outputMode,
      SettingsStrings.usbBitPerfect,
      SettingsStrings.replayGain,
      SettingsStrings.scrobbling,
      SettingsStrings.plugins,
      SettingsStrings.desktopTrayEnabled,
      SettingsStrings.backup,
      SettingsStrings.diagnosticLogs,
    ],
    SettingsCategory.about => [
      SettingsStrings.appVersion,
      SettingsStrings.coreVersion,
      SettingsStrings.author,
      SettingsStrings.githubRepo,
      SettingsStrings.reportBug,
      SettingsStrings.license,
      SettingsStrings.nameOriginTitle,
      SettingsStrings.deviceId,
      'GitHub',
      'Issue',
      'Bug',
      'aoxzh',
      'Lekismon',
    ],
  };

  String titleOf(BuildContext context) {
    context.l10n;
    return title;
  }

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
List<Widget> _appearanceSections() => const [
  _AppearanceSection(),
  _LyricsSection(),
  DesktopLyricsSettingsSection(),
];
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
    title: category.titleOf(context),
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
          subtitle: Text(SettingsStrings.libraryHealthHint),
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
              SettingsChoice<String?>(
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
                      DropdownMenuItem<String?>(
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
          subtitle: Text(EqualizerStrings.entryHint),
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
    final l10n = context.l10n;
    final pref = ref.watch(themePreferenceProvider);
    final localePref = ref.watch(appLocaleProvider);
    final npStyle = ref.watch(nowPlayingStyleProvider);
    final tabBarStyle = ref.watch(tabBarStyleProvider);
    final navBarPosition = ref.watch(navBarPositionProvider);
    final profile = UiProfile.current;
    void setTheme(ThemePreference p) =>
        settingsGuard(context, () => setThemePreference(ref, p));
    void setLocale(AppLocalePreference p) => settingsGuard(
      context,
      () => ref.read(appLocaleProvider.notifier).set(p),
    );
    void setNowPlayingStyle(NowPlayingStyle s) => settingsGuard(
      context,
      () => ref.read(nowPlayingStyleProvider.notifier).set(s),
    );
    return SettingsSection(
      title: l10n.appearance,
      children: [
        if (profile.desktopSettings) ...[
          SettingsDropdownTile<ThemePreference>(
            key: ValueKey('settings-theme'),
            icon: Icons.palette_outlined,
            title: SettingsStrings.theme,
            value: pref,
            choices: [
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
          ),
          SettingsDropdownTile<AppLocalePreference>(
            key: const ValueKey('settings-locale'),
            icon: Icons.language_rounded,
            title: l10n.language,
            subtitle: l10n.languageHint,
            value: localePref,
            choices: [
              SettingsChoice(AppLocalePreference.system, l10n.languageSystem),
              SettingsChoice(AppLocalePreference.zh, l10n.languageZh),
              SettingsChoice(AppLocalePreference.en, l10n.languageEn),
            ],
            onChanged: setLocale,
          ),
          SettingsDropdownTile<NowPlayingStyle>(
            key: const ValueKey('settings-now-playing-style'),
            icon: Icons.album_outlined,
            title: l10n.nowPlayingStyle,
            subtitle: l10n.nowPlayingStyleHint,
            value: npStyle,
            choices: [
              SettingsChoice(NowPlayingStyle.cover, l10n.styleCover),
              SettingsChoice(NowPlayingStyle.vinyl, l10n.styleVinyl),
              SettingsChoice(NowPlayingStyle.cassette, l10n.styleCassette),
            ],
            onChanged: setNowPlayingStyle,
          ),
        ] else ...[
          SettingsBlockTile(
            icon: Icons.palette_outlined,
            title: SettingsStrings.theme,
            hint: SettingsStrings.themeOledHint,
            child: SegmentedButton<ThemePreference>(
              showSelectedIcon: false,
              segments: [
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
          SettingsBlockTile(
            key: const ValueKey('settings-locale'),
            icon: Icons.language_rounded,
            title: l10n.language,
            hint: l10n.languageHint,
            child: SegmentedButton<AppLocalePreference>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: AppLocalePreference.system,
                  label: Text(l10n.languageSystem),
                ),
                ButtonSegment(
                  value: AppLocalePreference.zh,
                  label: Text(l10n.languageZh),
                ),
                ButtonSegment(
                  value: AppLocalePreference.en,
                  label: Text(l10n.languageEn),
                ),
              ],
              selected: {localePref},
              onSelectionChanged: (s) => setLocale(s.first),
            ),
          ),
          SettingsBlockTile(
            key: const ValueKey('settings-now-playing-style'),
            icon: Icons.album_outlined,
            title: l10n.nowPlayingStyle,
            hint: l10n.nowPlayingStyleHint,
            child: SegmentedButton<NowPlayingStyle>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: NowPlayingStyle.cover,
                  label: Text(l10n.styleCover),
                  icon: const Icon(Icons.image_outlined),
                ),
                ButtonSegment(
                  value: NowPlayingStyle.vinyl,
                  label: Text(l10n.styleVinyl),
                  icon: const Icon(Icons.album_outlined),
                ),
                ButtonSegment(
                  value: NowPlayingStyle.cassette,
                  label: Text(l10n.styleCassette),
                  icon: const Icon(Icons.voicemail_rounded),
                ),
              ],
              selected: {npStyle},
              onSelectionChanged: (s) => setNowPlayingStyle(s.first),
            ),
          ),
        ],
        // Liquid glass vs flat only exists where the glass tab bar does;
        // desktop always draws flat chrome, so the choice is not offered.
        if (profile.offersTabBarStyle) ...[
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
          SettingsBlockTile(
            key: ValueKey('settings-nav-bar-position'),
            icon: Icons.view_quilt_outlined,
            title: SettingsStrings.navBarPosition,
            hint: SettingsStrings.navBarPositionHint,
            child: SegmentedButton<NavBarPosition>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: NavBarPosition.bottom,
                  label: Text(SettingsStrings.navBarBottom),
                  icon: Icon(Icons.border_bottom_rounded),
                ),
                ButtonSegment(
                  value: NavBarPosition.left,
                  label: Text(SettingsStrings.navBarLeft),
                  icon: Icon(Icons.align_horizontal_left_rounded),
                ),
                ButtonSegment(
                  value: NavBarPosition.right,
                  label: Text(SettingsStrings.navBarRight),
                  icon: Icon(Icons.align_horizontal_right_rounded),
                ),
              ],
              selected: {navBarPosition},
              onSelectionChanged: (s) => settingsGuard(
                context,
                () => ref.read(navBarPositionProvider.notifier).set(s.first),
              ),
            ),
          ),
        ],
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
    // Android：独占输出就是 USB DAC 直出，输出模式完全由那个开关决定（核心也这样约束），
    // 所以不再单独提供「共享 / 独占」选择，免得两处互相矛盾。
    final usbTiles = usbBitPerfectTiles(ref);
    final usbOwnsMode = usbTiles.isNotEmpty;
    if (UiProfile.current.desktopSettings) {
      return SettingsSection(
        title: SettingsStrings.audioOutput,
        children: [
          ...usbTiles,
          if (!usbOwnsMode)
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
                SettingsChoice(
                  OutputModeDto.shared,
                  SettingsStrings.modeShared,
                ),
                SettingsChoice(
                  OutputModeDto.exclusive,
                  SettingsStrings.modeExclusive,
                  enabled: output.exclusiveSupported,
                ),
              ],
              onChanged: (m) =>
                  settingsGuard(context, () => notifier.setMode(m)),
            ),
          SettingsDropdownTile<ReplayGainMode>(
            icon: Icons.equalizer_rounded,
            title: SettingsStrings.replayGain,
            subtitle: SettingsStrings.replayGainHint,
            value: replayGain,
            choices: [
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
        ...usbTiles,
        if (!usbOwnsMode)
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
                ButtonSegment(
                  value: OutputModeDto.shared,
                  label: Text(SettingsStrings.modeShared),
                  icon: Icon(Icons.speaker_group_outlined),
                ),
                ButtonSegment(
                  value: OutputModeDto.exclusive,
                  label: Text(SettingsStrings.modeExclusive),
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
            segments: [
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
  Widget build(BuildContext context) => SettingsSection(
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
        subtitle: Text(SettingsStrings.diagnosticLogsHint),
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

const String _kAuthorHandle = '@aoxzh';
const String _kAuthorUrl = 'https://x.com/aoxzh';
const String _kRepoUrl = 'https://github.com/aoxzh/lekis-music';
const String _kIssuesUrl = 'https://github.com/aoxzh/lekis-music/issues';

class _AboutSection extends ConsumerStatefulWidget {
  const _AboutSection();

  @override
  ConsumerState<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<_AboutSection> {
  bool _checkingUpdate = false;

  Future<void> _openLink(BuildContext context, String url) async {
    final launched = await openExternalUrl(url);
    if (!launched) {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) {
        showFeatureSnack(context, SettingsStrings.linkCopiedFallback);
      }
    }
  }

  Future<void> _checkForUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    final result = await checkForAppUpdate();
    if (!mounted) return;
    setState(() => _checkingUpdate = false);

    switch (result) {
      case AppUpdateUpToDate(:final currentVersion):
        showFeatureSnack(context, SettingsStrings.upToDate(currentVersion));
      case AppUpdateError():
        showFeatureSnack(context, SettingsStrings.updateCheckFailed);
      case AppUpdateAvailable(:final info):
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(SettingsStrings.updateAvailableTitle(info.version)),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 320),
              child: SingleChildScrollView(
                child: Text(
                  info.notes.isEmpty
                      ? SettingsStrings.checkUpdatesHint
                      : info.notes,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  _openLink(context, info.releaseUrl);
                },
                child: Text(SettingsStrings.viewReleasePage),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  _openLink(context, info.downloadUrl);
                },
                child: Text(SettingsStrings.downloadUpdate),
              ),
            ],
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(aboutInfoProvider);
    final deviceId = info.deviceId;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final appName = L10n.tr('月兔音乐', 'Lekis Music');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LekisSpacing.lg,
            LekisSpacing.sm,
            LekisSpacing.lg,
            LekisSpacing.lg,
          ),
          child: Container(
            padding: const EdgeInsets.all(LekisSpacing.lg),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(LekisRadius.lg),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.55),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.asset(
                        'assets/brand/mark.png',
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: LekisSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            appName,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'v$kLekisAppVersion · MPL-2.0',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: LekisSpacing.md),
                Text(
                  SettingsStrings.nameOriginTitle,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  SettingsStrings.nameOriginBody,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
        SettingsSection(
          title: SettingsStrings.about,
          children: [
            SettingsTile(
              icon: Icons.system_update_outlined,
              title: SettingsStrings.checkUpdates,
              subtitle: Text(
                _checkingUpdate
                    ? SettingsStrings.checkingUpdates
                    : SettingsStrings.checkUpdatesHint,
              ),
              trailing: _checkingUpdate
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: _checkingUpdate ? null : _checkForUpdates,
            ),
            SettingsTile(
              icon: Icons.person_outline_rounded,
              title: SettingsStrings.author,
              subtitle: const Text('$_kAuthorHandle · $_kAuthorUrl'),
              trailing: const Icon(Icons.open_in_new_rounded, size: 18),
              onTap: () => _openLink(context, _kAuthorUrl),
            ),
            SettingsTile(
              icon: Icons.bug_report_outlined,
              title: SettingsStrings.reportBug,
              subtitle: Text(SettingsStrings.reportBugHint),
              trailing: const Icon(Icons.open_in_new_rounded, size: 18),
              onTap: () => _openLink(context, _kIssuesUrl),
            ),
            SettingsTile(
              icon: Icons.code_rounded,
              title: SettingsStrings.githubRepo,
              subtitle: const Text('github.com/aoxzh/lekis-music'),
              trailing: const Icon(Icons.open_in_new_rounded, size: 18),
              onTap: () => _openLink(context, _kRepoUrl),
            ),
            SettingsTile(
              icon: Icons.tag_rounded,
              title: SettingsStrings.appVersion,
              trailing: const Text(kLekisAppVersion),
            ),
            SettingsTile(
              icon: Icons.memory_outlined,
              title: SettingsStrings.coreVersion,
              trailing: Text(info.coreVersion ?? SettingsStrings.unavailable),
            ),
            SettingsTile(
              icon: Icons.gavel_outlined,
              title: SettingsStrings.license,
              trailing: const Text('MPL-2.0'),
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
        ),
      ],
    );
  }
}
