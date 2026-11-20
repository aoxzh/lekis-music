// 设置页：播放、外观、资料库、听歌记录、备份、关于。

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/dto.dart';
import '../../shell/app_shell.dart';
import '../../shell/tab_bar_style.dart';
import '../../theme/tokens.dart';
import '../downloads/downloads_models.dart';
import '../downloads/downloads_providers.dart';
import 'logs_page.dart';
import '../enrich/enrich_providers.dart';
import '../now_playing/lyrics_stage_settings.dart';
import '../player/sleep_timer.dart';
import '../plugins/plugins_providers.dart';
import '../sources/common.dart';
import 'scrobble_providers.dart';
import 'settings_backup.dart';
import 'settings_providers.dart';
import 'strings.dart';
import 'tab_bar_style_picker.dart';
import 'theme_preference.dart';
import 'widgets/settings_widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScaffold(
    title: SettingsStrings.title,
    body: SettingsListView(
      children: [
        _PlaybackSection(),
        _AppearanceSection(),
        _LibrarySection(),
        _ScrobbleSection(),
        SettingsBackupSection(),
        _AboutSection(),
      ],
    ),
  );
}

Future<void> _guard(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      showFeatureSnack(
        context,
        '${SettingsStrings.saveFailed}：${describeCoreError(e)}',
      );
    }
  }
}

// ---------------------------------------------------------------------------
// 播放
// ---------------------------------------------------------------------------

class _PlaybackSection extends ConsumerWidget {
  const _PlaybackSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(playbackOutputProvider);
    final notifier = ref.read(playbackOutputProvider.notifier);
    final gapless = ref.watch(settingProvider(SettingKeys.gapless));
    final replayGain = ReplayGainMode.fromStorage(
      ref.watch(settingProvider(SettingKeys.replayGain)).value,
    );
    final colors = context.lekisColors;
    final text = Theme.of(context).textTheme;
    final error = output.error;

    return SettingsSection(
      title: SettingsStrings.playback,
      children: [
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
                      _guard(context, () => notifier.selectDevice(id)),
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
                _guard(context, () => notifier.setMode(s.first)),
          ),
        ),
        SettingsSwitchTile(
          icon: Icons.linear_scale_rounded,
          title: SettingsStrings.gapless,
          subtitle: SettingsStrings.gaplessHint,
          value: gapless.value != 'false',
          onChanged: gapless.isLoading
              ? null
              : (v) => _guard(
                  context,
                  () => ref
                      .read(settingProvider(SettingKeys.gapless).notifier)
                      .set(v ? 'true' : 'false'),
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
            onSelectionChanged: (s) => _guard(
              context,
              () => ref
                  .read(settingProvider(SettingKeys.replayGain).notifier)
                  .set(s.first.storageValue),
            ),
          ),
        ),
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
                  selected: ref.watch(sleepTimerProvider).kind == kind,
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
    final stage = ref.watch(lyricsStageStyleProvider);
    final sparks = ref.watch(lyricsSparksProvider);
    return SettingsSection(
      title: SettingsStrings.appearance,
      children: [
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
            onSelectionChanged: (s) =>
                _guard(context, () => setThemePreference(ref, s.first)),
          ),
        ),
        SettingsBlockTile(
          icon: Icons.space_dashboard_outlined,
          title: SettingsStrings.tabBarStyle,
          hint: SettingsStrings.tabBarStyleHint,
          child: TabBarStylePicker(
            selected: tabBarStyle,
            onChanged: (style) => _guard(
              context,
              () => ref.read(tabBarStyleProvider.notifier).set(style),
            ),
          ),
        ),
        SettingsBlockTile(
          icon: Icons.lyrics_outlined,
          title: SettingsStrings.lyricsStage,
          hint: SettingsStrings.lyricsStageHint,
          child: LyricsStageStyleSelector(
            selected: stage,
            onChanged: (next) => _guard(
              context,
              () => ref
                  .read(settingProvider(SettingKeys.lyricsStage).notifier)
                  .set(next.storageValue),
            ),
          ),
        ),
        SettingsSwitchTile(
          icon: Icons.auto_awesome_outlined,
          title: SettingsStrings.lyricsSparks,
          subtitle: SettingsStrings.lyricsSparksHint,
          value: sparks,
          onChanged: (on) => _guard(
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
// 资料库（含插件入口）
// ---------------------------------------------------------------------------

class _LibrarySection extends ConsumerWidget {
  const _LibrarySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(enrichPendingCountProvider);
    final downloads = ref.watch(downloadsSummaryProvider);
    return SettingsSection(
      title: SettingsStrings.library,
      children: [
        SettingsTile(
          icon: Icons.storage_outlined,
          title: SettingsStrings.sources,
          subtitle: const Text(SettingsStrings.sourcesHint),
          chevron: true,
          onTap: () => AppShell.select(context, LekisDestination.sources),
        ),
        SettingsTile(
          icon: Icons.download_for_offline_outlined,
          title: SettingsStrings.downloads,
          subtitle: Text(
            downloads.readyCount > 0 || downloads.activeCount > 0
                ? SettingsStrings.downloadsSummary(
                    downloads.readyCount,
                    formatBytes(downloads.totalBytes),
                    downloads.activeCount,
                  )
                : SettingsStrings.downloadsHint,
          ),
          trailing: downloads.activeCount > 0
              ? const SizedBox.square(
                  dimension: LekisSpacing.lg,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          chevron: true,
          onTap: () => openDownloads(context),
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
        const PluginsSettingsTile(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 插件
// ---------------------------------------------------------------------------

/// 设置页里的插件入口。放在这里方便单独测试列表摘要状态。
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

// ---------------------------------------------------------------------------
// 听歌记录（DIS-07）
// ---------------------------------------------------------------------------

class _ScrobbleSection extends ConsumerStatefulWidget {
  const _ScrobbleSection();

  @override
  ConsumerState<_ScrobbleSection> createState() => _ScrobbleSectionState();
}

class _ScrobbleSectionState extends ConsumerState<_ScrobbleSection> {
  final _username = TextEditingController();
  final _apiKey = TextEditingController();
  final _apiSecret = TextEditingController();
  final _sessionKey = TextEditingController();
  final _userToken = TextEditingController();

  bool _loaded = false;
  bool _enabled = false;
  bool _nowPlaying = true;
  String _service = 'lastfm';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    final settings = ref.read(scrobbleProvider).settings;
    if (settings == null) return;
    _enabled = settings.enabled;
    _nowPlaying = settings.nowPlaying;
    _service = settings.service;
    _username.text = settings.username ?? '';
    _loaded = true;
  }

  @override
  void dispose() {
    _username.dispose();
    _apiKey.dispose();
    _apiSecret.dispose();
    _sessionKey.dispose();
    _userToken.dispose();
    super.dispose();
  }

  String? _secret(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? null : text;
  }

  Future<void> _save({bool snack = false}) async {
    final settings = ref.read(scrobbleProvider).settings;
    if (settings == null) return;
    final input = ScrobbleSettingsInputDto(
      enabled: _enabled,
      service: _service,
      username: _username.text.trim(),
      nowPlaying: _nowPlaying,
      apiKey: _secret(_apiKey),
      apiSecret: _secret(_apiSecret),
      sessionKey: _secret(_sessionKey),
      userToken: _secret(_userToken),
    );
    await _guard(context, () async {
      await ref.read(scrobbleProvider.notifier).save(input);
      // 保存成功后清空输入框里的明文；已保存状态用 has* 布尔值展示。
      _apiKey.clear();
      _apiSecret.clear();
      _sessionKey.clear();
      _userToken.clear();
      if (snack && mounted) {
        showFeatureSnack(context, SettingsStrings.scrobbleSaved);
      }
    });
  }

  Future<void> _clearSecrets() async {
    final settings = ref.read(scrobbleProvider).settings;
    if (settings == null) return;
    final input = ScrobbleSettingsInputDto(
      enabled: _enabled,
      service: _service,
      username: _username.text.trim(),
      nowPlaying: _nowPlaying,
      apiKey: '',
      apiSecret: '',
      sessionKey: '',
      userToken: '',
    );
    await _guard(context, () async {
      await ref.read(scrobbleProvider.notifier).save(input);
      _apiKey.clear();
      _apiSecret.clear();
      _sessionKey.clear();
      _userToken.clear();
    });
  }

  Future<void> _test() async {
    try {
      await ref.read(scrobbleProvider.notifier).test();
      final error = ref.read(scrobbleProvider).status?.lastError;
      if (mounted) {
        showFeatureSnack(
          context,
          error == null
              ? SettingsStrings.scrobbleTestOk
              : '${SettingsStrings.scrobbleTestFailed}：$error',
        );
      }
    } catch (e) {
      if (mounted) {
        showFeatureSnack(
          context,
          '${SettingsStrings.scrobbleTestFailed}：${describeCoreError(e)}',
        );
      }
    }
  }

  String _statusText(ScrobbleStatusDto? status) {
    if (status == null) return SettingsStrings.unavailable;
    final error = status.lastError;
    if (error != null && error.isNotEmpty) return error;
    if (!status.enabled) return SettingsStrings.scrobbleDisabled;
    if (!status.configured) return SettingsStrings.scrobbleNotConfigured;
    return '${SettingsStrings.scrobbleReady} · ${SettingsStrings.scrobbleQueue(status.queued)}';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scrobbleProvider);
    final settings = state.settings;
    final status = state.status;
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    if (settings == null) {
      return const SettingsSection(
        title: SettingsStrings.scrobbling,
        children: [
          SettingsTile(
            icon: Icons.history_rounded,
            title: SettingsStrings.scrobbleEnable,
            subtitle: Text(SettingsStrings.unavailable),
          ),
        ],
      );
    }
    if (!_loaded) {
      // 核心初始化较慢时，设置可能在第一帧之后才可用。
      _enabled = settings.enabled;
      _nowPlaying = settings.nowPlaying;
      _service = settings.service;
      _username.text = settings.username ?? '';
      _loaded = true;
    }

    final lastFmFamily = _service != 'listenbrainz';
    return SettingsSection(
      title: SettingsStrings.scrobbling,
      children: [
        SettingsSwitchTile(
          icon: Icons.history_rounded,
          title: SettingsStrings.scrobbleEnable,
          subtitle: SettingsStrings.scrobbleEnableHint,
          value: _enabled,
          onChanged: (value) async {
            setState(() => _enabled = value);
            await _save();
          },
        ),
        SettingsTile(
          icon: Icons.cloud_outlined,
          title: SettingsStrings.scrobbleService,
          trailing: DropdownButton<String>(
            value: _service,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(LekisRadius.md),
            items: const [
              DropdownMenuItem(
                value: 'lastfm',
                child: Text(SettingsStrings.scrobbleLastFm),
              ),
              DropdownMenuItem(
                value: 'listenbrainz',
                child: Text(SettingsStrings.scrobbleListenBrainz),
              ),
              DropdownMenuItem(
                value: 'librefm',
                child: Text(SettingsStrings.scrobbleLibreFm),
              ),
            ],
            onChanged: (value) async {
              if (value == null) return;
              setState(() => _service = value);
              await _save();
            },
          ),
        ),
        SettingsBlockTile(
          icon: Icons.key_outlined,
          title: SettingsStrings.scrobbleAccount,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(
                  labelText: SettingsStrings.scrobbleUsername,
                  isDense: true,
                ),
                textInputAction: TextInputAction.next,
              ),
              if (lastFmFamily) ...[
                _SecretField(
                  controller: _apiKey,
                  label: SettingsStrings.scrobbleApiKey,
                  saved: settings.hasApiKey,
                ),
                _SecretField(
                  controller: _apiSecret,
                  label: SettingsStrings.scrobbleApiSecret,
                  saved: settings.hasApiSecret,
                ),
                _SecretField(
                  controller: _sessionKey,
                  label: SettingsStrings.scrobbleSessionKey,
                  saved: settings.hasSessionKey,
                ),
              ] else
                _SecretField(
                  controller: _userToken,
                  label: SettingsStrings.scrobbleUserToken,
                  saved: settings.hasUserToken,
                ),
            ],
          ),
        ),
        SettingsSwitchTile(
          icon: Icons.podcasts_rounded,
          title: SettingsStrings.scrobbleNowPlaying,
          subtitle: SettingsStrings.scrobbleNowPlayingHint,
          value: _nowPlaying,
          onChanged: (value) async {
            setState(() => _nowPlaying = value);
            await _save();
          },
        ),
        SettingsBlockTile(
          icon: status?.lastError != null
              ? Icons.error_outline_rounded
              : Icons.check_circle_outline_rounded,
          title: _statusText(status),
          titleStyle: theme.textTheme.bodyMedium?.copyWith(
            color: status?.lastError != null
                ? colors.danger
                : colors.onSurfaceVariant,
          ),
          child: Wrap(
            spacing: LekisSpacing.sm,
            runSpacing: LekisSpacing.sm,
            children: [
              FilledButton(
                onPressed: () => _save(snack: true),
                child: const Text(SettingsStrings.scrobbleSave),
              ),
              OutlinedButton(
                onPressed: state.testing ? null : _test,
                child: state.testing
                    ? const SizedBox.square(
                        dimension: LekisSpacing.lg,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text(SettingsStrings.scrobbleTest),
              ),
              TextButton(
                onPressed: _clearSecrets,
                child: const Text(SettingsStrings.scrobbleClearSecrets),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SecretField extends StatelessWidget {
  const _SecretField({
    required this.controller,
    required this.label,
    required this.saved,
  });

  final TextEditingController controller;
  final String label;
  final bool saved;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: LekisSpacing.sm),
    child: TextFormField(
      controller: controller,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: saved ? SettingsStrings.scrobbleSecretKept : null,
        isDense: true,
      ),
      textInputAction: TextInputAction.next,
    ),
  );
}

// ---------------------------------------------------------------------------
// 关于（含诊断日志，SET-03）
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
}
