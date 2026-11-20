// 听歌记录（DIS-07）：入口行 + 独立子页面（服务、凭据、测试）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/dto.dart';
import '../../theme/tokens.dart';
import '../sources/common.dart';
import 'scrobble_providers.dart';
import 'settings_guard.dart';
import 'strings.dart';
import 'widgets/settings_widgets.dart';

String _scrobbleStatusText(ScrobbleStatusDto? status) {
  if (status == null) return SettingsStrings.unavailable;
  final error = status.lastError;
  if (error != null && error.isNotEmpty) return error;
  if (!status.enabled) return SettingsStrings.scrobbleDisabled;
  if (!status.configured) return SettingsStrings.scrobbleNotConfigured;
  return '${SettingsStrings.scrobbleReady} · ${SettingsStrings.scrobbleQueue(status.queued)}';
}

/// 高级设置里的入口行：一句话状态 + 箭头。
class ScrobbleSettingsTile extends ConsumerWidget {
  const ScrobbleSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(scrobbleProvider);
    final status = state.status;
    return SettingsTile(
      icon: Icons.history_rounded,
      title: SettingsStrings.scrobbling,
      subtitle: Text(
        status == null || !status.enabled
            ? SettingsStrings.scrobbleHint
            : _scrobbleStatusText(status),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      chevron: true,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ScrobbleSettingsPage()),
      ),
    );
  }
}

class ScrobbleSettingsPage extends StatelessWidget {
  const ScrobbleSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScaffold(
    title: SettingsStrings.scrobbling,
    body: SettingsListView(children: [ScrobbleSettingsSection()]),
  );
}

class ScrobbleSettingsSection extends ConsumerStatefulWidget {
  const ScrobbleSettingsSection({super.key});

  @override
  ConsumerState<ScrobbleSettingsSection> createState() =>
      _ScrobbleSettingsSectionState();
}

class _ScrobbleSettingsSectionState
    extends ConsumerState<ScrobbleSettingsSection> {
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
    _load(settings);
  }

  void _load(ScrobbleSettingsDto settings) {
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

  void _clearInputs() {
    _apiKey.clear();
    _apiSecret.clear();
    _sessionKey.clear();
    _userToken.clear();
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
    await settingsGuard(context, () async {
      await ref.read(scrobbleProvider.notifier).save(input);
      // 保存成功后清空输入框里的明文；已保存状态用 has* 布尔值展示。
      _clearInputs();
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
    await settingsGuard(context, () async {
      await ref.read(scrobbleProvider.notifier).save(input);
      _clearInputs();
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
    // 核心初始化较慢时，设置可能在第一帧之后才可用。
    if (!_loaded) _load(settings);

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
          title: _scrobbleStatusText(status),
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
