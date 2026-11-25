import '../../l10n/app_l10n.dart';
// 插件详情 / 设置面板。设置项由清单声明，密码值永远不回显。

import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';

import '../../platform/ui_profile.dart';
import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';
import '../../theme/tokens.dart';
import '../library/widgets/page_gutter.dart';
import '../settings/widgets/settings_widgets.dart';
import '../sources/common.dart';
import 'plugin_format.dart';
import 'plugin_browse_page.dart';
import 'strings.dart';

/// A settings page on mobile, a centred detail window on desktop.
Future<void> showPluginDetailSheet(BuildContext context, PluginInfoDto plugin) {
  if (UiProfile.current.prefersSheets) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScaffold(
          title: plugin.name,
          body: _PluginDetailSheet(plugin: plugin, fullPage: true),
        ),
      ),
    );
  }
  return showLekisSheet<void>(
    context,
    heightFactor: 0.92,
    builder: (_) => _PluginDetailSheet(plugin: plugin),
  );
}

class _PluginDetailSheet extends StatefulWidget {
  const _PluginDetailSheet({required this.plugin, this.fullPage = false});
  final bool fullPage;

  final PluginInfoDto plugin;

  @override
  State<_PluginDetailSheet> createState() => _PluginDetailSheetState();
}

class _PluginDetailSheetState extends State<_PluginDetailSheet> {
  late Future<List<PluginSettingDto>> _settings;

  @override
  void initState() {
    super.initState();
    _settings = _load();
  }

  Future<List<PluginSettingDto>> _load() {
    if (widget.plugin.error != null) return Future.value(const []);
    return core.pluginSettings(pluginId: widget.plugin.id);
  }

  void _retry() => setState(() => _settings = _load());

  @override
  Widget build(BuildContext context) {
    final plugin = widget.plugin;
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        context.featureGutter,
        0,
        context.featureGutter,
        widget.fullPage ? scrollEndPadding(context) : LekisSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.fullPage)
            SelectableText(
              plugin.id,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(plugin.name, style: theme.textTheme.titleLarge),
                      const SizedBox(height: LekisSpacing.xxs),
                      SelectableText(
                        plugin.id,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: PluginStrings.close,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          const SizedBox(height: LekisSpacing.sm),
          Wrap(
            spacing: LekisSpacing.sm,
            runSpacing: LekisSpacing.sm,
            children: [
              _InfoChip(label: pluginVersionLabel(plugin.version)),
              _InfoChip(label: pluginKindsLabel(plugin.kinds)),
              _InfoChip(label: pluginRuntimeLabel(plugin.runtime)),
              _InfoChip(
                label: plugin.enabled
                    ? PluginStrings.enabled
                    : PluginStrings.disabled,
                emphasised: plugin.enabled,
              ),
            ],
          ),
          if (plugin.compatibility == 'mygo') ...[
            const SizedBox(height: LekisSpacing.md),
            Text(
              context.l10n.pick(
                'MyGO 兼容插件：支持搜索、公开内容浏览和直接音频播放。网页登录、远程播放及后台转码暂不支持。',
                'MyGO compatibility: search, public collections and direct audio. Web sign-in, remote playback and background transcoding are unavailable.',
              ),
            ),
            if (plugin.enabled && plugin.error == null)
              TextButton.icon(
                icon: const Icon(Icons.folder_outlined),
                label: Text(context.l10n.pick('浏览音源', 'Browse source')),
                onPressed: () =>
                    Navigator.of(context)
                        .push(PluginBrowsePage.route(plugin.id, plugin.name)),
              ),
          ],
          if (plugin.error != null) ...[
            const SizedBox(height: LekisSpacing.md),
            _ErrorBox(message: plugin.error!),
          ],
          const SizedBox(height: LekisSpacing.lg),
          SettingsSectionHeader(PluginStrings.info),
          _DetailTable(
            rows: [
              (PluginStrings.kind, pluginKindsLabel(plugin.kinds)),
              (PluginStrings.runtime, pluginRuntimeLabel(plugin.runtime)),
              if (plugin.entry != null && plugin.entry!.isNotEmpty)
                (PluginStrings.entry, plugin.entry!),
              if (plugin.author != null && plugin.author!.isNotEmpty)
                (PluginStrings.author, plugin.author!),
              if (plugin.homepage != null && plugin.homepage!.isNotEmpty)
                (PluginStrings.homepage, plugin.homepage!),
              (PluginStrings.directory, plugin.directory),
              (
                PluginStrings.permissions,
                pluginPermissionSummary(plugin.permissions),
              ),
            ],
          ),
          const SizedBox(height: LekisSpacing.xl),
          if (plugin.error == null &&
              plugin.permissions.nativeAndroid &&
              defaultTargetPlatform == TargetPlatform.android)
            _NativeAndroidPermission(plugin: plugin),
          if (plugin.error == null &&
              defaultTargetPlatform != TargetPlatform.android &&
              defaultTargetPlatform != TargetPlatform.iOS)
            for (final program in plugin.permissions.process)
              _ProcessPermission(pluginId: plugin.id, program: program),
          SettingsSectionHeader(PluginStrings.settings),
          if (plugin.error != null)
            Text(
              PluginStrings.invalidManifest,
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.danger),
            )
          else
            FutureBuilder<List<PluginSettingDto>>(
              future: _settings,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(LekisSpacing.lg),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        PluginStrings.settingsLoadFailed,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.danger,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: Text(PluginStrings.retry),
                      ),
                    ],
                  );
                }
                final settings = snapshot.data ?? const <PluginSettingDto>[];
                if (settings.isEmpty) {
                  return Text(
                    PluginStrings.noSettings,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  );
                }
                return _SettingsEditor(pluginId: plugin.id, settings: settings);
              },
            ),
        ],
      ),
    );
  }
}

class _SettingsEditor extends StatefulWidget {
  const _SettingsEditor({required this.pluginId, required this.settings});

  final String pluginId;
  final List<PluginSettingDto> settings;

  @override
  State<_SettingsEditor> createState() => _SettingsEditorState();
}

class _SettingsEditorState extends State<_SettingsEditor> {
  late final Map<String, TextEditingController> _controllers;
  late final Map<String, bool> _booleans;
  late final Map<String, String> _selections;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final setting in widget.settings)
        if (setting.kind == 'string' || setting.kind == 'password')
          setting.key: TextEditingController(
            text: setting.kind == 'password'
                ? ''
                : setting.value ?? setting.defaultValue ?? '',
          ),
    };
    _booleans = {
      for (final setting in widget.settings)
        if (setting.kind == 'boolean')
          setting.key: _asBool(setting.value ?? setting.defaultValue),
    };
    _selections = {
      for (final setting in widget.settings)
        if (setting.kind == 'select') setting.key: _selectionValue(setting),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  static bool _asBool(String? value) =>
      value == 'true' || value == '1' || value == 'on';

  static String _selectionValue(PluginSettingDto setting) {
    final current = setting.value ?? setting.defaultValue;
    if (current != null && setting.options.contains(current)) return current;
    return setting.options.isEmpty ? '' : setting.options.first;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      for (final setting in widget.settings) {
        final String value;
        switch (setting.kind) {
          case 'boolean':
            value = (_booleans[setting.key] ?? false).toString();
          case 'select':
            value = _selections[setting.key] ?? '';
          case 'password':
            final text = _controllers[setting.key]?.text ?? '';
            // 空密码表示保留已保存的值；密码本身不写日志、不回显。
            if (text.trim().isEmpty) continue;
            value = text;
          default:
            value = _controllers[setting.key]?.text ?? '';
        }
        await core.setPluginSetting(
          pluginId: widget.pluginId,
          key: setting.key,
          value: value,
        );
      }
      if (!mounted) return;
      showFeatureSnack(context, PluginStrings.settingsSaved);
    } catch (error) {
      if (!mounted) return;
      showFeatureSnack(
        context,
        '${PluginStrings.settingsFailed}：${describeCoreError(error)}',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final setting in widget.settings) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: LekisSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (setting.kind != 'boolean') ...[
                  Text(setting.label, style: theme.textTheme.bodyLarge),
                  if (setting.help != null && setting.help!.isNotEmpty) ...[
                    const SizedBox(height: LekisSpacing.xxs),
                    Text(
                      setting.help!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: LekisSpacing.sm),
                ],
                switch (setting.kind) {
                  'boolean' => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      setting.label,
                      style: theme.textTheme.bodyLarge,
                    ),
                    subtitle: setting.help == null || setting.help!.isEmpty
                        ? null
                        : Text(
                            setting.help!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                    value: _booleans[setting.key] ?? false,
                    onChanged: _saving
                        ? null
                        : (value) =>
                              setState(() => _booleans[setting.key] = value),
                  ),
                  'select' => SettingsSelectField<String>(
                    title: setting.label,
                    icon: Icons.tune_rounded,
                    value: _selections[setting.key] ?? '',
                    choices: [
                      for (final option in setting.options)
                        SettingsChoice(option, option),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) =>
                              setState(() => _selections[setting.key] = value),
                  ),
                  'password' => Semantics(
                    label: setting.label,
                    child: TextField(
                      enabled: !_saving,
                      controller: _controllers[setting.key],
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        hintText: setting.hasValue
                            ? PluginStrings.secretKept
                            : null,
                        suffixIcon: setting.hasValue
                            ? const Icon(Icons.lock_outline)
                            : null,
                      ),
                    ),
                  ),
                  _ => Semantics(
                    label: setting.label,
                    child: TextField(
                      enabled: !_saving,
                      controller: _controllers[setting.key],
                    ),
                  ),
                },
                if (setting.secret && setting.hasValue) ...[
                  const SizedBox(height: LekisSpacing.xxs),
                  Text(
                    PluginStrings.secretSaved,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: LekisSpacing.xxs),
                Text(
                  '${PluginStrings.settingKey}：${setting.key}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: LekisSpacing.lg,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(PluginStrings.saveSettings),
          ),
        ),
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, this.emphasised = false});

  final String label;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.sm,
        vertical: LekisSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: emphasised
            ? colors.accent.withValues(alpha: 0.14)
            : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(LekisRadius.pill),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: emphasised ? colors.accent : colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 插件信息：标签列按内容自适应宽度，放在与设置页相同的分组面板里。
class _DetailTable extends StatelessWidget {
  const _DetailTable({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: settingsPanelDecoration(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.lg,
          vertical: LekisSpacing.md,
        ),
        child: Table(
          columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
          children: [
            for (final (label, value) in rows)
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(
                      right: LekisSpacing.lg,
                      bottom: LekisSpacing.xs,
                    ),
                    child: Text(label, style: theme.textTheme.bodySmall),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: LekisSpacing.xs),
                    child: SelectableText(
                      value,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(LekisSpacing.md),
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(LekisRadius.md),
        border: Border.all(color: colors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: colors.danger),
          const SizedBox(width: LekisSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  PluginStrings.manifestError,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.danger,
                  ),
                ),
                const SizedBox(height: LekisSpacing.xxs),
                SelectableText(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.danger,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Process grants belong to the host, separate from plugin-controlled settings.
class _ProcessPermission extends StatefulWidget {
  const _ProcessPermission({required this.pluginId, required this.program});
  final String pluginId;
  final String program;
  @override
  State<_ProcessPermission> createState() => _ProcessPermissionState();
}

class _ProcessPermissionState extends State<_ProcessPermission> {
  late final String _key =
      'plugin.process.${widget.pluginId}.${widget.program}';
  late Future<String?> _grant = core.getSetting(key: _key);
  bool _saving = false;

  Future<void> _set(bool value) async {
    setState(() => _saving = true);
    try {
      await core.setSetting(key: _key, value: value.toString());
      if (mounted) setState(() => _grant = Future.value(value.toString()));
    } catch (error) {
      if (mounted) showFeatureSnack(context, describeCoreError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _grant,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return TextButton(
          onPressed: () => setState(() => _grant = core.getSetting(key: _key)),
          child: Text(
            context.l10n.pick('重试读取程序权限', 'Retry loading process permission'),
          ),
        );
      }
      return SettingsSwitchTile(
        icon: Icons.terminal_rounded,
        title: context.l10n.pick(
          '允许启动 ${widget.program}',
          'Allow running ${widget.program}',
        ),
        subtitle: context.l10n.pick(
          '仅桌面端。请先安装该程序；允许后，程序可以访问本机文件和网络。',
          'Desktop only. Install the program first. It can access local files and the network.',
        ),
        value: snapshot.data == 'true',
        onChanged: _saving || snapshot.connectionState != ConnectionState.done
            ? null
            : _set,
      );
    },
  );
}

/// Native code runs with the app's permissions, outside the JavaScript sandbox.
class _NativeAndroidPermission extends StatefulWidget {
  const _NativeAndroidPermission({required this.plugin});
  final PluginInfoDto plugin;

  @override
  State<_NativeAndroidPermission> createState() =>
      _NativeAndroidPermissionState();
}

class _NativeAndroidPermissionState extends State<_NativeAndroidPermission> {
  late bool _allowed = widget.plugin.nativeAndroidGranted;
  bool _saving = false;

  Future<void> _set(bool value) async {
    setState(() => _saving = true);
    try {
      await core.setPluginNativeAndroidAllowed(
        pluginId: widget.plugin.id,
        allowed: value,
      );
      if (mounted) setState(() => _allowed = value);
    } catch (error) {
      if (mounted) showFeatureSnack(context, describeCoreError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsSwitchTile(
    icon: Icons.extension_outlined,
    title: context.l10n.pick('允许运行 Android 扩展', 'Allow Android extension'),
    subtitle: context.l10n.pick(
      '扩展代码与应用拥有相同权限，可以访问应用数据和网络，不受插件域名限制。请仅允许你信任的插件。关闭后将停止后续调用，已经运行的代码可能仍会继续。',
      'Native code has the same permissions as the app, including app data and network access, without plugin domain restrictions. Only allow plugins you trust. Turning this off blocks future calls; running code may continue.',
    ),
    value: _allowed,
    onChanged: _saving ? null : _set,
  );
}
