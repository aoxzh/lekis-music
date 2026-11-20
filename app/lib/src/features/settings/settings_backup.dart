// Settings export/import (SET-02, JSON subset): copy a JSON map to the
// clipboard, paste it back to restore. Secrets are deliberately excluded.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/settings/theme_preference.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:material_ui/material_ui.dart';

import 'strings.dart';
import 'widgets/settings_widgets.dart';

const _backupKeys = [
  SettingKeys.gapless,
  SettingKeys.replayGain,
  SettingKeys.outputDevice,
  SettingKeys.outputMode,
  themeSettingKey,
  tabBarStyleSettingKey,
  'ui.lyrics_stage',
  'ui.lyrics_sparks',
];

TextStyle? _monospace(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.bodySmall?.copyWith(
    fontFamily: 'monospace',
    color: theme.colorScheme.onSurface,
  );
}

class SettingsBackupSection extends ConsumerWidget {
  const SettingsBackupSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSection(
      title: SettingsStrings.backup,
      children: [
        SettingsTile(
          icon: Icons.upload_file_outlined,
          title: '导出设置',
          subtitle: const Text('生成 JSON 并复制到剪贴板（不含密码和播放历史）'),
          onTap: () => _export(context),
        ),
        SettingsTile(
          icon: Icons.download_outlined,
          title: '导入设置',
          subtitle: const Text('粘贴之前导出的 JSON，覆盖当前设置'),
          onTap: () => _import(context, ref),
        ),
      ],
    );
  }

  Future<void> _export(BuildContext context) async {
    final map = <String, String>{};
    for (final key in _backupKeys) {
      final value = await core.getSetting(key: key);
      if (value != null) map[key] = value;
    }
    final text = const JsonEncoder.withIndent('  ').convert(map);
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置已复制'),
        content: SingleChildScrollView(
          child: SelectableText(text, style: _monospace(context)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入设置'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 8,
          maxLines: 14,
          style: _monospace(context),
          decoration: const InputDecoration(
            hintText: '粘贴导出的 JSON',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty || !context.mounted) return;

    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('顶层必须是 JSON 对象');
      }
      var applied = 0;
      for (final entry in decoded.entries) {
        if (!_backupKeys.contains(entry.key)) continue;
        final value = entry.value;
        if (value is! String) continue;
        await core.setSetting(key: entry.key, value: value);
        ref.invalidate(settingProvider(entry.key));
        applied++;
      }
      final theme = decoded[themeSettingKey];
      if (theme is String) {
        await setThemePreference(ref, ThemePreference.fromStorage(theme));
      }
      final tab = decoded[tabBarStyleSettingKey];
      if (tab is String) {
        await ref
            .read(tabBarStyleProvider.notifier)
            .set(TabBarStyle.fromStorage(tab));
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导入 $applied 项设置')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }
}
