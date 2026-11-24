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
import '../../theme/theme_settings.dart';
import '../../theme/tokens.dart';
import '../enrich/enrich_providers.dart';
import '../library/library_health_page.dart';
import '../now_playing/lyrics_ruby.dart';
import '../now_playing/lyrics_stage_settings.dart';
import '../now_playing/now_playing_style.dart';
import '../player/sleep_timer.dart';
import '../plugins/plugins_providers.dart';
import '../sources/common.dart';
import 'app_updater_provider.dart';
import 'desktop_self_updater.dart';
import 'desktop_tray_settings_section.dart';
import 'equalizer_page.dart';
import 'logs_page.dart';
import 'lyrics_presets.dart';
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
  advanced(Icons.tune_rounded, SettingsCategoryGroup.more, _advancedSections),
  about(Icons.info_outline_rounded, SettingsCategoryGroup.more, _aboutSections);

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
      SettingsStrings.lyricsPresets,
      SettingsStrings.styleEnsemble,
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
  const _ImageCacheSection(),
  if (UiProfile.current.pointerFirst) const _ShortcutsSection(),
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
    final writeSidecars = ref.watch(
      settingProvider(SettingKeys.writeEnrichSidecars),
    );
    final backfill = ref.watch(settingProvider(SettingKeys.sidecarBackfill));
    final sidecarEnabled = writeSidecars.value != 'false';
    final sidecarHint = !sidecarEnabled
        ? SettingsStrings.writeEnrichSidecarsHint
        : backfill.value == 'done'
        ? SettingsStrings.sidecarBackfillDone
        : SettingsStrings.sidecarBackfillPending;
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
        SettingsSwitchTile(
          icon: Icons.save_alt_rounded,
          title: SettingsStrings.writeEnrichSidecars,
          subtitle: sidecarHint,
          value: sidecarEnabled,
          onChanged: writeSidecars.isLoading
              ? null
              : (v) => settingsGuard(
                  context,
                  () => ref
                      .read(
                        settingProvider(SettingKeys.writeEnrichSidecars)
                            .notifier,
                      )
                      .set(v ? 'true' : 'false'),
                ),
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
              SettingsChoice<String?>(null, SettingsStrings.systemDefault),
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
    final accent = ref.watch(accentProvider);
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
              style: const ButtonStyle(
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
              segments: [
                ButtonSegment(
                  value: ThemePreference.system,
                  label: Text(
                    SettingsStrings.themeSystem,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                  ),
                ),
                ButtonSegment(
                  value: ThemePreference.light,
                  label: Text(
                    SettingsStrings.themeLight,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                  ),
                ),
                ButtonSegment(
                  value: ThemePreference.dark,
                  label: Text(
                    SettingsStrings.themeDark,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                  ),
                ),
                ButtonSegment(
                  value: ThemePreference.oledBlack,
                  label: Text(
                    SettingsStrings.themeOled,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                  ),
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
        SettingsBlockTile(
          key: const ValueKey('settings-accent'),
          icon: Icons.color_lens_outlined,
          title: SettingsStrings.accentColor,
          hint: SettingsStrings.accentColorHint,
          child: Wrap(
            spacing: LekisSpacing.sm,
            runSpacing: LekisSpacing.xs,
            children: [
              for (final option in LekisAccent.values)
                ChoiceChip(
                  key: ValueKey('settings-accent-${option.id}'),
                  avatar: CircleAvatar(
                    backgroundColor: option.colorFor(
                      Theme.of(context).brightness,
                    ),
                    radius: 8,
                  ),
                  label: Text(_accentLabel(l10n, option)),
                  selected: accent == option,
                  onSelected: (_) => settingsGuard(
                    context,
                    () => setAccentPreference(ref, option),
                  ),
                ),
            ],
          ),
        ),
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

String _accentLabel(L10n l10n, LekisAccent accent) => switch (accent) {
  LekisAccent.moonrise => l10n.pick('月升紫', 'Moonrise'),
  LekisAccent.ocean => l10n.pick('深海蓝', 'Ocean'),
  LekisAccent.forest => l10n.pick('森林绿', 'Forest'),
  LekisAccent.rose => l10n.pick('玫瑰红', 'Rose'),
  LekisAccent.amber => l10n.pick('琥珀金', 'Amber'),
};

class _LyricsSection extends ConsumerWidget {
  const _LyricsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsStyle = ref.watch(lyricsStyleProvider);
    final sparks = ref.watch(lyricsSparksProvider);
    final ruby = ref.watch(lyricsRubyProvider);
    final fontScale = ref.watch(settingProvider(SettingKeys.lyricsFontScale));
    final translation = ref.watch(
      settingProvider(SettingKeys.lyricsTranslation),
    );
    final scale =
        fontScale.value == '0.85' ||
            fontScale.value == '1.15' ||
            fontScale.value == '1.3'
        ? fontScale.value!
        : '1';
    void setStyle(LyricsStyle next) => settingsGuard(
      context,
      () => ref
          .read(settingProvider(SettingKeys.lyricsStage).notifier)
          .set(next.storageValue),
    );
    void setRuby(LyricsRubyMode next) => settingsGuard(
      context,
      () => ref
          .read(settingProvider(SettingKeys.lyricsRuby).notifier)
          .set(next.storageValue),
    );
    return SettingsSection(
      title: SettingsStrings.lyrics,
      children: [
        const LyricsPresetTile(),
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
        SettingsDropdownTile<String>(
          key: const ValueKey('settings-lyrics-font-size'),
          icon: Icons.format_size_rounded,
          title: SettingsStrings.lyricsFontSize,
          subtitle: SettingsStrings.lyricsFontSizeHint,
          value: scale,
          choices: [
            SettingsChoice('0.85', SettingsStrings.lyricsFontSmall),
            SettingsChoice('1', SettingsStrings.lyricsFontNormal),
            SettingsChoice('1.15', SettingsStrings.lyricsFontLarge),
            SettingsChoice('1.3', SettingsStrings.lyricsFontXLarge),
          ],
          onChanged: (value) => settingsGuard(
            context,
            () => ref
                .read(settingProvider(SettingKeys.lyricsFontScale).notifier)
                .set(value),
          ),
        ),
        SettingsSwitchTile(
          icon: Icons.translate_rounded,
          title: SettingsStrings.lyricsTranslation,
          subtitle: SettingsStrings.lyricsTranslationHint,
          value: translation.value != 'false',
          onChanged: (on) => settingsGuard(
            context,
            () => ref
                .read(settingProvider(SettingKeys.lyricsTranslation).notifier)
                .set(on ? 'true' : 'false'),
          ),
        ),
        // 火花只对逐字舞台有意义，经典视图下不显示这个开关。
        if (lyricsStyle.stage != null)
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
        // 注音目前只在经典视图上画（舞台是逐字排版，见 lyrics_ruby.dart 的说明）。
        if (!lyricsStyle.isStage)
          SettingsDropdownTile<LyricsRubyMode>(
            icon: Icons.translate_rounded,
            title: SettingsStrings.lyricsRuby,
            subtitle: SettingsStrings.lyricsRubyHint,
            value: ruby,
            choices: [
              for (final mode in LyricsRubyMode.values)
                SettingsChoice(mode, mode.label),
            ],
            onChanged: setRuby,
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

String _formatCacheBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

class _ImageCacheSection extends StatefulWidget {
  const _ImageCacheSection();

  @override
  State<_ImageCacheSection> createState() => _ImageCacheSectionState();
}

class _ImageCacheSectionState extends State<_ImageCacheSection> {
  void _clear() {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    setState(() {});
    showFeatureSnack(
      context,
      context.l10n.pick('已清除图片缓存', 'Image cache cleared'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cache = PaintingBinding.instance.imageCache;
    final used = _formatCacheBytes(cache.currentSizeBytes);
    final max = _formatCacheBytes(cache.maximumSizeBytes);
    return SettingsSection(
      title: context.l10n.pick('性能', 'Performance'),
      children: [
        SettingsTile(
          icon: Icons.image_outlined,
          title: context.l10n.pick('图片缓存', 'Image cache'),
          subtitle: Text(
            context.l10n.pick(
              '$used / $max · ${cache.currentSize} 张',
              '$used / $max · ${cache.currentSize} images',
            ),
          ),
          trailing: TextButton(
            onPressed: cache.currentSize == 0 ? null : _clear,
            child: Text(context.l10n.pick('清除', 'Clear')),
          ),
        ),
      ],
    );
  }
}

class _ShortcutsSection extends StatelessWidget {
  const _ShortcutsSection();

  Future<void> _showShortcuts(BuildContext context) async {
    final l10n = context.l10n;
    await showDialog<void>(
      context: context,
      builder: (dialog) {
        final theme = Theme.of(dialog);
        Widget row(String keys, String label) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 160,
                child: Text(
                  keys,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(child: Text(label)),
            ],
          ),
        );
        return AlertDialog(
          title: Text(l10n.pick('播放快捷键', 'Playback Shortcuts')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row('Space', l10n.pick('播放 / 暂停', 'Play / pause')),
                row(
                  'Ctrl/Cmd + ← / →',
                  l10n.pick('上一首 / 下一首', 'Previous / next'),
                ),
                row(
                  'Ctrl/Cmd + ↑ / ↓',
                  l10n.pick('音量 +5% / -5%', 'Volume +5% / -5%'),
                ),
                row(
                  'Shift + ← / →',
                  l10n.pick('后退 / 前进 10 秒', 'Seek -10s / +10s'),
                ),
                row(
                  'Media keys',
                  l10n.pick('播放/暂停、上一首、下一首', 'Play/pause, previous, next'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: Text(l10n.pick('关闭', 'Close')),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsSection(
      title: l10n.pick('键盘快捷键', 'Keyboard Shortcuts'),
      children: [
        SettingsTile(
          icon: Icons.keyboard_outlined,
          title: l10n.pick('查看播放快捷键', 'View playback shortcuts'),
          subtitle: Text(
            l10n.pick(
              '空格播放/暂停，Ctrl+方向键切换或调节音量',
              'Space to play/pause, Ctrl+arrows to skip or change volume',
            ),
          ),
          chevron: true,
          onTap: () => _showShortcuts(context),
        ),
      ],
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
  Future<void> _openLink(BuildContext context, String url) async {
    final launched = await openExternalUrl(url);
    if (!launched) {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) {
        showFeatureSnack(context, SettingsStrings.linkCopiedFallback);
      }
    }
  }

  Future<void> _handleUpdateTileTap() async {
    final current = ref.read(appUpdaterProvider);
    if (current.phase == AppUpdaterPhase.available ||
        current.phase == AppUpdaterPhase.downloading ||
        current.phase == AppUpdaterPhase.ready) {
      await _showUpdateDialog();
      return;
    }

    final result = await ref
        .read(appUpdaterProvider.notifier)
        .checkForUpdates();
    if (!mounted || result == null) return;

    switch (result) {
      case AppUpdateUpToDate(:final currentVersion):
        showFeatureSnack(context, SettingsStrings.upToDate(currentVersion));
      case AppUpdateError():
        showFeatureSnack(context, SettingsStrings.updateCheckFailed);
      case AppUpdateAvailable():
        await _showUpdateDialog();
    }
  }

  Future<void> _showUpdateDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) =>
          _UpdateDialog(onOpenLink: (url) => _openLink(context, url)),
    );
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
            _buildUpdateTile(ref.watch(appUpdaterProvider), scheme),
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

  Widget _buildUpdateTile(AppUpdaterState update, ColorScheme scheme) {
    final busy =
        update.phase == AppUpdaterPhase.checking ||
        update.phase == AppUpdaterPhase.restarting;
    final subtitle = switch (update.phase) {
      AppUpdaterPhase.checking => SettingsStrings.checkingUpdates,
      AppUpdaterPhase.available when update.info != null =>
        SettingsStrings.updateAvailableSubtitle(update.info!.version),
      AppUpdaterPhase.downloading => _formatProgressLine(update.progress),
      AppUpdaterPhase.ready when update.info != null =>
        SettingsStrings.updateReadySubtitle(update.info!.version),
      AppUpdaterPhase.restarting => SettingsStrings.restartingToUpdate,
      _ => SettingsStrings.checkUpdatesHint,
    };

    Widget trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (update.phase == AppUpdaterPhase.downloading) {
      trailing = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: update.progress?.fraction,
        ),
      );
    } else if (update.phase == AppUpdaterPhase.ready ||
        update.phase == AppUpdaterPhase.available) {
      trailing = Icon(
        update.phase == AppUpdaterPhase.ready
            ? Icons.restart_alt_rounded
            : Icons.download_rounded,
        size: 20,
        color: scheme.primary,
      );
    } else {
      trailing = const Icon(Icons.chevron_right_rounded, size: 20);
    }

    return SettingsTile(
      icon: Icons.system_update_outlined,
      title: SettingsStrings.checkUpdates,
      subtitle: Text(subtitle),
      trailing: trailing,
      onTap: busy ? null : _handleUpdateTileTap,
    );
  }
}

class _UpdateDialog extends ConsumerWidget {
  const _UpdateDialog({required this.onOpenLink});

  final Future<void> Function(String url) onOpenLink;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdaterProvider);
    final notifier = ref.read(appUpdaterProvider.notifier);
    final info = state.info;
    if (info == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canInApp = state.canInAppUpdate;
    final progress = state.progress;

    return AlertDialog(
      title: Text(SettingsStrings.updateAvailableTitle(info.version)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  info.notes.isEmpty
                      ? SettingsStrings.checkUpdatesHint
                      : info.notes,
                ),
              ),
            ),
            if (state.phase == AppUpdaterPhase.downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: progress?.fraction),
              const SizedBox(height: 8),
              Text(
                _formatProgressLine(progress),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ] else if (state.phase == AppUpdaterPhase.ready) ...[
              const SizedBox(height: 14),
              Text(
                SettingsStrings.updateReadyHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ] else if (state.phase == AppUpdaterPhase.restarting) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(SettingsStrings.restartingToUpdate)),
                ],
              ),
            ] else if (state.phase == AppUpdaterPhase.error &&
                state.errorMessage != null) ...[
              const SizedBox(height: 14),
              Text(
                state.errorMessage!,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ] else if (!canInApp && state.capability?.reason != null) ...[
              const SizedBox(height: 12),
              Text(
                state.capability!.reason!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: switch (state.phase) {
        AppUpdaterPhase.downloading => [
          TextButton(
            onPressed: notifier.cancelDownload,
            child: Text(SettingsStrings.cancel),
          ),
        ],
        AppUpdaterPhase.ready => [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(SettingsStrings.later),
          ),
          FilledButton.icon(
            onPressed: notifier.restartToUpdate,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: Text(SettingsStrings.restartToUpdate),
          ),
        ],
        AppUpdaterPhase.restarting => const [],
        AppUpdaterPhase.error when canInApp => [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onOpenLink(info.downloadUrl);
            },
            child: Text(SettingsStrings.viewReleasePage),
          ),
          FilledButton(
            onPressed: notifier.downloadAndStage,
            child: Text(SettingsStrings.retry),
          ),
        ],
        _ when canInApp => [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onOpenLink(info.releaseUrl);
            },
            child: Text(SettingsStrings.viewReleasePage),
          ),
          FilledButton.icon(
            onPressed: notifier.downloadAndStage,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(SettingsStrings.downloadAndUpdate),
          ),
        ],
        _ => [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onOpenLink(info.releaseUrl);
            },
            child: Text(SettingsStrings.viewReleasePage),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              onOpenLink(info.downloadUrl);
            },
            child: Text(SettingsStrings.downloadUpdate),
          ),
        ],
      },
    );
  }
}

String _formatProgressLine(UpdateDownloadProgress? progress) {
  if (progress == null) return SettingsStrings.downloadingUpdate;
  switch (progress.step) {
    case UpdateStep.verifying:
      return SettingsStrings.verifyingUpdate;
    case UpdateStep.extracting:
      return SettingsStrings.extractingUpdate;
    case UpdateStep.downloading:
      final rec = _formatMegabytes(progress.receivedBytes);
      if (progress.totalBytes > 0) {
        final tot = _formatMegabytes(progress.totalBytes);
        final pct = ((progress.fraction ?? 0) * 100).round();
        final speed = progress.bytesPerSecond > 0
            ? ' · ${_formatSpeed(progress.bytesPerSecond)}'
            : '';
        return '$rec / $tot ($pct%)$speed';
      }
      return rec;
  }
}

String _formatMegabytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _formatSpeed(double bytesPerSecond) {
  final mb = bytesPerSecond / (1024 * 1024);
  if (mb >= 1) return '${mb.toStringAsFixed(1)} MB/s';
  final kb = bytesPerSecond / 1024;
  return '${kb.toStringAsFixed(0)} KB/s';
}
