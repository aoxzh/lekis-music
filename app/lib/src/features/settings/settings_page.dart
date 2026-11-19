// 设置页：播放、外观、资料库、关于。

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/dto.dart';
import '../../shell/app_shell.dart';
import '../../shell/tab_bar_style.dart';
import '../../theme/tokens.dart';
import '../enrich/enrich_providers.dart';
import '../now_playing/lyrics_stage_settings.dart';
import '../sources/common.dart';
import 'scrobble_providers.dart';
import 'settings_providers.dart';
import 'strings.dart';
import 'tab_bar_style_picker.dart';
import 'theme_preference.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(SettingsStrings.title)),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: featureMaxContentWidth),
        child: ListView(
          padding: EdgeInsets.symmetric(
            horizontal: context.featureGutter,
            vertical: LekisSpacing.lg,
          ),
          children: const [
            _Section(
              title: SettingsStrings.playback,
              child: _PlaybackSection(),
            ),
            _Section(
              title: SettingsStrings.appearance,
              child: _AppearanceSection(),
            ),
            _Section(title: SettingsStrings.library, child: _LibrarySection()),
            _Section(
              title: SettingsStrings.scrobbling,
              child: _ScrobbleSection(),
            ),
            _Section(title: SettingsStrings.about, child: _AboutSection()),
          ],
        ),
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: LekisSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: LekisSpacing.lg,
              bottom: LekisSpacing.sm,
            ),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: colors.accent),
              ),
            ),
          ),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: colors.surfaceVariant,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(LekisRadius.lg),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置行里放在标题下面的控件（分段按钮等）。
class _BlockTile extends StatelessWidget {
  const _BlockTile({required this.title, required this.child, this.hint});

  final String title;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.lg,
        vertical: LekisSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.bodyLarge),
          const SizedBox(height: LekisSpacing.sm),
          SizedBox(width: double.infinity, child: child),
          if (hint != null) ...[
            const SizedBox(height: LekisSpacing.sm),
            Text(
              hint!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
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
    final error = output.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          minTileHeight: LekisSizes.touchTargetMin,
          title: const Text(SettingsStrings.outputDevice),
          subtitle: error != null
              ? Text(
                  describeCoreError(error),
                  style: TextStyle(color: colors.danger),
                )
              : output.devices.isEmpty
              ? const Text(SettingsStrings.noDevices)
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (output.devices.isNotEmpty)
                Flexible(
                  child: DropdownButton<String?>(
                    value: output.selectedDeviceId,
                    isDense: false,
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
              IconButton(
                tooltip: SettingsStrings.refreshDevices,
                onPressed: notifier.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        _BlockTile(
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
        SwitchListTile(
          title: const Text(SettingsStrings.gapless),
          subtitle: const Text(SettingsStrings.gaplessHint),
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
        _BlockTile(
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BlockTile(
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
        const Divider(
          indent: LekisSpacing.lg,
          endIndent: LekisSpacing.lg,
          height: 1,
        ),
        _BlockTile(
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
        _BlockTile(
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
        SwitchListTile(
          title: const Text(SettingsStrings.lyricsSparks),
          subtitle: const Text(SettingsStrings.lyricsSparksHint),
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
// 资料库
// ---------------------------------------------------------------------------

class _LibrarySection extends ConsumerWidget {
  const _LibrarySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(enrichPendingCountProvider);
    return Column(
      children: [
        ListTile(
          minTileHeight: LekisSizes.touchTargetMin,
          leading: const Icon(Icons.storage_outlined),
          title: const Text(SettingsStrings.sources),
          subtitle: const Text(SettingsStrings.sourcesHint),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => AppShell.select(context, LekisDestination.sources),
        ),
        ListTile(
          minTileHeight: LekisSizes.touchTargetMin,
          leading: const Icon(Icons.auto_fix_high_outlined),
          title: const Text(SettingsStrings.enrichReview),
          subtitle: Text(
            pending != null && pending > 0
                ? SettingsStrings.pendingCount(pending)
                : SettingsStrings.enrichReviewHint,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pending != null && pending > 0) Badge.count(count: pending),
              const SizedBox(width: LekisSpacing.sm),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => openEnrichReview(context),
        ),
      ],
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
      return const Padding(
        padding: EdgeInsets.all(LekisSpacing.lg),
        child: Text(SettingsStrings.unavailable),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text(SettingsStrings.scrobbleEnable),
          subtitle: const Text(SettingsStrings.scrobbleEnableHint),
          value: _enabled,
          onChanged: (value) async {
            setState(() => _enabled = value);
            await _save();
          },
        ),
        _BlockTile(
          title: SettingsStrings.scrobbleService,
          child: DropdownButton<String>(
            value: _service,
            isExpanded: true,
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
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LekisSpacing.lg,
            vertical: LekisSpacing.xs,
          ),
          child: TextFormField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: SettingsStrings.scrobbleUsername,
              isDense: true,
            ),
            textInputAction: TextInputAction.next,
          ),
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
        SwitchListTile(
          title: const Text(SettingsStrings.scrobbleNowPlaying),
          subtitle: const Text(SettingsStrings.scrobbleNowPlayingHint),
          value: _nowPlaying,
          onChanged: (value) async {
            setState(() => _nowPlaying = value);
            await _save();
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LekisSpacing.lg,
            vertical: LekisSpacing.xs,
          ),
          child: Text(
            _statusText(status),
            style: theme.textTheme.bodySmall?.copyWith(
              color: status?.lastError != null ? colors.danger : colors.onSurfaceVariant,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LekisSpacing.lg,
            vertical: LekisSpacing.sm,
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
                    ? const SizedBox(
                        width: 16,
                        height: 16,
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
    padding: const EdgeInsets.symmetric(
      horizontal: LekisSpacing.lg,
      vertical: LekisSpacing.xs,
    ),
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
// 关于
// ---------------------------------------------------------------------------

class _AboutSection extends ConsumerWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(aboutInfoProvider);
    final deviceId = info.deviceId;
    return Column(
      children: [
        ListTile(
          minTileHeight: LekisSizes.touchTargetMin,
          title: const Text(SettingsStrings.coreVersion),
          trailing: Text(info.coreVersion ?? SettingsStrings.unavailable),
        ),
        ListTile(
          minTileHeight: LekisSizes.touchTargetMin,
          title: const Text(SettingsStrings.deviceId),
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
