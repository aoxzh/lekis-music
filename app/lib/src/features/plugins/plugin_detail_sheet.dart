// 插件详情 / 设置面板。设置项由清单声明，密码值永远不回显。

import 'package:material_ui/material_ui.dart';

import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';
import '../../theme/tokens.dart';
import '../sources/common.dart';
import 'plugin_format.dart';
import 'strings.dart';

Future<void> showPluginDetailSheet(
  BuildContext context,
  PluginInfoDto plugin,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => FractionallySizedBox(
    heightFactor: 0.92,
    child: _PluginDetailSheet(plugin: plugin),
  ),
);

class _PluginDetailSheet extends StatefulWidget {
  const _PluginDetailSheet({required this.plugin});

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
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.featureGutter,
          LekisSpacing.sm,
          context.featureGutter,
          LekisSpacing.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.outline,
                  borderRadius: BorderRadius.circular(LekisRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: LekisSpacing.md),
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
            if (plugin.error != null) ...[
              const SizedBox(height: LekisSpacing.md),
              _ErrorBox(message: plugin.error!),
            ],
            const SizedBox(height: LekisSpacing.lg),
            _DetailRow(label: PluginStrings.kind, value: pluginKindsLabel(plugin.kinds)),
            _DetailRow(label: PluginStrings.runtime, value: pluginRuntimeLabel(plugin.runtime)),
            if (plugin.entry != null && plugin.entry!.isNotEmpty)
              _DetailRow(label: PluginStrings.entry, value: plugin.entry!),
            if (plugin.author != null && plugin.author!.isNotEmpty)
              _DetailRow(label: PluginStrings.author, value: plugin.author!),
            if (plugin.homepage != null && plugin.homepage!.isNotEmpty)
              _DetailRow(label: PluginStrings.homepage, value: plugin.homepage!),
            _DetailRow(label: PluginStrings.directory, value: plugin.directory),
            const SizedBox(height: LekisSpacing.md),
            Text(PluginStrings.permissions, style: theme.textTheme.titleMedium),
            const SizedBox(height: LekisSpacing.xs),
            Text(
              pluginPermissionSummary(plugin.permissions),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: LekisSpacing.lg),
            Divider(color: colors.outline, height: 1),
            const SizedBox(height: LekisSpacing.lg),
            Text(PluginStrings.settings, style: theme.textTheme.titleMedium),
            const SizedBox(height: LekisSpacing.sm),
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
                          label: const Text(PluginStrings.retry),
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
                  return _SettingsEditor(
                    pluginId: plugin.id,
                    settings: settings,
                  );
                },
              ),
          ],
        ),
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
        if (setting.kind == 'select')
          setting.key: _selectionValue(setting),
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
                switch (setting.kind) {
                  'boolean' => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      (_booleans[setting.key] ?? false)
                          ? PluginStrings.enabled
                          : PluginStrings.disabled,
                    ),
                    value: _booleans[setting.key] ?? false,
                    onChanged: _saving
                        ? null
                        : (value) =>
                              setState(() => _booleans[setting.key] = value),
                  ),
                  'select' => DropdownButton<String>(
                    value: _selections[setting.key],
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    borderRadius: BorderRadius.circular(LekisRadius.md),
                    items: [
                      for (final option in setting.options)
                        DropdownMenuItem(value: option, child: Text(option)),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() => _selections[setting.key] = value);
                          },
                  ),
                  'password' => TextField(
                    controller: _controllers[setting.key],
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: setting.hasValue
                          ? PluginStrings.secretKept
                          : null,
                      suffixIcon: setting.hasValue
                          ? const Icon(Icons.lock_outline)
                          : null,
                    ),
                  ),
                  _ => TextField(
                    controller: _controllers[setting.key],
                    decoration: const InputDecoration(isDense: true),
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
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text(PluginStrings.saveSettings),
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: LekisSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodySmall),
          ),
        ],
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
          Icon(Icons.error_outline, color: colors.danger, size: 20),
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
