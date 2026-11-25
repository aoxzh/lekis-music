// Settings export/import (SET-02, JSON subset): copy a JSON map to the
// clipboard, paste it back to restore. Secrets are deliberately excluded.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/now_playing_style.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/settings/theme_preference.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/l10n/app_locale.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/shell/nav_bar_position.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

import 'strings.dart';
import 'widgets/settings_widgets.dart';

const _backupKeys = [
  SettingKeys.gapless,
  SettingKeys.video,
  SettingKeys.replayGain,
  SettingKeys.outputDevice,
  SettingKeys.outputMode,
  themeSettingKey,
  appLocaleSettingKey,
  nowPlayingStyleSettingKey,
  tabBarStyleSettingKey,
  navBarPositionSettingKey,
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
    final l10n = context.l10n;
    return SettingsSection(
      title: SettingsStrings.backup,
      children: [
        SettingsTile(
          icon: Icons.upload_file_outlined,
          title: l10n.pick('导出设置', 'Export Settings'),
          subtitle: Text(
            l10n.pick(
              '生成 JSON 并复制到剪贴板（不含密码和播放历史）',
              'Copy settings JSON to clipboard (excludes passwords & history)',
            ),
          ),
          onTap: () => _export(context),
        ),
        SettingsTile(
          icon: Icons.download_outlined,
          title: l10n.pick('导入设置', 'Import Settings'),
          subtitle: Text(
            l10n.pick(
              '粘贴之前导出的 JSON，覆盖当前设置',
              'Paste exported JSON to restore settings',
            ),
          ),
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
    await showLekisPanel<void>(
      context,
      builder: (context) => LekisPanel(
        title: context.l10n.pick('设置已复制', 'Settings Copied'),
        body: SelectableText(text, style: _monospace(context)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.pick('关闭', 'Close')),
          ),
        ],
      ),
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    String? error;
    final decoded = await showLekisPanel<Map<String, dynamic>>(
      context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => LekisPanel(
          title: context.l10n.pick('导入设置', 'Import Settings'),
          body: TextField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 14,
            style: _monospace(context),
            onChanged: (_) {
              if (error != null) setState(() => error = null);
            },
            decoration: InputDecoration(
              hintText: context.l10n.pick('粘贴导出的 JSON', 'Paste exported JSON'),
              errorText: error,
              errorMaxLines: 2,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.pick('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final data = jsonDecode(controller.text);
                  if (data is Map<String, dynamic>) {
                    Navigator.of(context).pop(data);
                  } else {
                    setState(
                      () => error = context.l10n.pick(
                        '顶层必须是 JSON 对象',
                        'Top-level value must be a JSON object',
                      ),
                    );
                  }
                } on FormatException {
                  setState(
                    () => error = context.l10n.pick(
                      '无法读取 JSON，请检查格式',
                      'Check the JSON format',
                    ),
                  );
                }
              },
              child: Text(context.l10n.pick('导入', 'Import')),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (decoded == null || !context.mounted) return;
    try {
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
      final navPos = decoded[navBarPositionSettingKey];
      if (navPos is String) {
        await ref
            .read(navBarPositionProvider.notifier)
            .set(NavBarPosition.fromStorage(navPos));
      }
      final locale = decoded[appLocaleSettingKey];
      if (locale is String) {
        await ref
            .read(appLocaleProvider.notifier)
            .set(AppLocalePreference.fromStorage(locale));
      }
      final npStyle = decoded[nowPlayingStyleSettingKey];
      if (npStyle is String) {
        await ref
            .read(nowPlayingStyleProvider.notifier)
            .set(NowPlayingStyle.fromStorage(npStyle));
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.pick('已导入 $applied 项设置', 'Imported $applied settings'),
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.pick('导入失败：$e', 'Import failed: $e')),
        ),
      );
    }
  }
}
