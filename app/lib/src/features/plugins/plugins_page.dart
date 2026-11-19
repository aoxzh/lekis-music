// 本地插件管理页：安装、启用 / 停用、移除和打开插件设置。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';
import '../../rust/api/error.dart';
import '../../theme/tokens.dart';
import '../sources/common.dart';
import 'plugin_detail_sheet.dart';
import 'plugin_format.dart';
import 'plugins_providers.dart';
import 'strings.dart';

enum _InstallChoice { folder, zip }

enum _DirectoryAction { copy, open }

class PluginsPage extends ConsumerStatefulWidget {
  const PluginsPage({super.key});

  @override
  ConsumerState<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends ConsumerState<PluginsPage> {
  final Set<String> _busy = {};
  bool _installing = false;

  Future<void> _toggle(PluginInfoDto plugin, bool enabled) => _run(
    plugin.id,
    () => ref.read(pluginListProvider.notifier).setEnabled(plugin.id, enabled),
  );

  Future<void> _remove(PluginInfoDto plugin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(PluginStrings.removeTitle),
        content: Text(PluginStrings.removeBody(plugin.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(PluginStrings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.lekisColors.danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(PluginStrings.confirmRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      plugin.id,
      () => ref.read(pluginListProvider.notifier).remove(plugin.id),
      success: PluginStrings.removed,
    );
  }

  Future<void> _run(
    String pluginId,
    Future<void> Function() action, {
    String? success,
  }) async {
    setState(() => _busy.add(pluginId));
    try {
      await action();
      if (success != null && mounted) showFeatureSnack(context, success);
    } catch (error) {
      if (mounted) {
        showFeatureSnack(
          context,
          '${PluginStrings.actionFailed}：${describeCoreError(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(pluginId));
    }
  }

  Future<void> _chooseInstall() async {
    final choice = await showModalBottomSheet<_InstallChoice>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LekisSpacing.xl,
                LekisSpacing.lg,
                LekisSpacing.xl,
                LekisSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    PluginStrings.install,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: LekisSpacing.xs),
                  Text(
                    PluginStrings.installHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.lekisColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              minTileHeight: LekisSizes.touchTargetMin,
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text(PluginStrings.installFolder),
              onTap: () =>
                  Navigator.of(context).pop(_InstallChoice.folder),
            ),
            ListTile(
              minTileHeight: LekisSizes.touchTargetMin,
              leading: const Icon(Icons.folder_zip_outlined),
              title: const Text(PluginStrings.installZip),
              onTap: () => Navigator.of(context).pop(_InstallChoice.zip),
            ),
            const SizedBox(height: LekisSpacing.sm),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _InstallChoice.folder:
        await _installFolder();
      case _InstallChoice.zip:
        await _installZip();
      case null:
        break;
    }
  }

  Future<void> _installFolder() async {
    try {
      final directory = await FilePicker.pickDirectory(
        dialogTitle: PluginStrings.installFolder,
      );
      if (!mounted || directory == null) return;
      final path = _localDirectoryPath(directory);
      if (path == null) {
        // Android 的 SAF 目录是 content:// URI，Rust 侧拿不到真实路径；让用户改用 zip。
        showFeatureSnack(context, PluginStrings.installFolderUnsupported);
        return;
      }
      await _install(path);
    } catch (error) {
      _showInstallError(error);
    }
  }

  String? _localDirectoryPath(Uri uri) {
    if (uri.scheme == 'file') return uri.toFilePath();
    if (uri.scheme.isEmpty) return uri.path;
    return null;
  }

  Future<void> _installZip() async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: PluginStrings.installZip,
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      if (!mounted || files.isEmpty) return;
      final path = files.single.path;
      if (path == null) {
        showFeatureSnack(context, PluginStrings.installNoPath);
        return;
      }
      await _install(path);
    } catch (error) {
      _showInstallError(error);
    }
  }

  Future<void> _install(String path) async {
    setState(() => _installing = true);
    try {
      final plugin = await ref.read(pluginListProvider.notifier).install(path);
      if (mounted) {
        showFeatureSnack(
          context,
          '${PluginStrings.installed}：${plugin.name}',
        );
      }
    } catch (error) {
      _showInstallError(error);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  void _showInstallError(Object error) {
    if (!mounted) return;
    final kind = coreErrorKind(error);
    final message = kind == ErrorKind.invalidArgument
        ? PluginStrings.installInvalid
        : '${PluginStrings.installFailed}：${describeCoreError(error)}';
    showFeatureSnack(context, message);
  }

  Future<void> _showDirectory() async {
    final String path;
    try {
      path = core.pluginsDir();
    } catch (error) {
      if (mounted) {
        showFeatureSnack(
          context,
          '${PluginStrings.pluginDir}：${describeCoreError(error)}',
        );
      }
      return;
    }
    if (!mounted) return;
    final action = await showDialog<_DirectoryAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(PluginStrings.pluginDir),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(PluginStrings.pluginDirHint),
            const SizedBox(height: LekisSpacing.md),
            SelectableText(path),
          ],
        ),
        actions: [
          if (Platform.isWindows || Platform.isLinux)
            TextButton(
              onPressed: () => Navigator.of(context).pop(_DirectoryAction.open),
              child: const Text(PluginStrings.openInExplorer),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_DirectoryAction.copy),
            child: const Text(PluginStrings.copyPath),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(PluginStrings.close),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _DirectoryAction.copy:
        await Clipboard.setData(ClipboardData(text: path));
        if (mounted) showFeatureSnack(context, PluginStrings.copied);
      case _DirectoryAction.open:
        await _openDirectory(path);
      case null:
        break;
    }
  }

  Future<void> _openDirectory(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      }
    } catch (error) {
      if (mounted) {
        showFeatureSnack(
          context,
          '${PluginStrings.pluginDir}：${describeCoreError(error)}',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final plugins = ref.watch(pluginListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text(PluginStrings.title),
        actions: [
          IconButton(
            tooltip: PluginStrings.refresh,
            onPressed: plugins.isLoading
                ? null
                : () => ref.read(pluginListProvider.notifier).reload(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: PluginStrings.pluginDir,
            onPressed: _showDirectory,
            icon: const Icon(Icons.folder_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: LekisSpacing.sm),
            child: IconButton.filledTonal(
              tooltip: PluginStrings.install,
              onPressed: _installing ? null : _chooseInstall,
              icon: const Icon(Icons.add),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_installing) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: plugins.when(
              skipLoadingOnReload: true,
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (error, _) => _ErrorState(
                message: PluginStrings.loadFailed,
                detail: describeCoreError(error),
                onRetry: () =>
                    ref.read(pluginListProvider.notifier).reload(),
              ),
              data: (list) => list.isEmpty
                  ? _EmptyState(
                      installing: _installing,
                      onInstallFolder: _installFolder,
                      onInstallZip: _installZip,
                    )
                  : Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: featureMaxContentWidth,
                        ),
                        child: ListView.separated(
                          padding: EdgeInsets.all(context.featureGutter),
                          itemCount: list.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: LekisSpacing.sm),
                          itemBuilder: (_, index) {
                            final plugin = list[index];
                            return _PluginCard(
                              plugin: plugin,
                              busy: _busy.contains(plugin.id),
                              onToggle: (enabled) =>
                                  _toggle(plugin, enabled),
                              onRemove: () => _remove(plugin),
                              onOpen: () =>
                                  showPluginDetailSheet(context, plugin),
                            );
                          },
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.busy,
    required this.onToggle,
    required this.onRemove,
    required this.onOpen,
  });

  final PluginInfoDto plugin;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRemove;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final hasError = plugin.error != null;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceVariant,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.lg),
      ),
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(LekisSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: hasError
                          ? colors.danger.withValues(alpha: 0.12)
                          : colors.accentSoft,
                      borderRadius: BorderRadius.circular(LekisRadius.md),
                    ),
                    child: Icon(
                      hasError
                          ? Icons.error_outline
                          : Icons.extension_outlined,
                      color: hasError ? colors.danger : colors.accent,
                    ),
                  ),
                  const SizedBox(width: LekisSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                plugin.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            if (hasError) ...[
                              const SizedBox(width: LekisSpacing.xs),
                              Text(
                                PluginStrings.manifestError,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colors.danger,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: LekisSpacing.xxs),
                        Text(
                          pluginSummaryLine(plugin),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: LekisSpacing.xxs),
                        Text(
                          plugin.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: LekisSpacing.sm),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.all(LekisSpacing.md),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    Switch(
                      value: plugin.enabled,
                      onChanged: hasError ? null : onToggle,
                    ),
                  IconButton(
                    tooltip: PluginStrings.remove,
                    onPressed: busy ? null : onRemove,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              const SizedBox(height: LekisSpacing.sm),
              if (hasError)
                _InlineError(message: plugin.error!)
              else
                Text(
                  pluginPermissionSummary(plugin.permissions),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Container(
      padding: const EdgeInsets.all(LekisSpacing.sm),
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(LekisRadius.sm),
      ),
      child: Text(
        message,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.installing,
    required this.onInstallFolder,
    required this.onInstallZip,
  });

  final bool installing;
  final VoidCallback onInstallFolder;
  final VoidCallback onInstallZip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: featureMaxContentWidth),
        child: ListView(
          padding: EdgeInsets.all(context.featureGutter),
          children: [
            const SizedBox(height: LekisSpacing.xxl),
            Icon(
              Icons.extension_outlined,
              size: 56,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(height: LekisSpacing.md),
            Text(
              PluginStrings.emptyTitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: LekisSpacing.sm),
            Text(
              PluginStrings.emptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: LekisSpacing.xl),
            Center(
              child: Wrap(
                spacing: LekisSpacing.sm,
                runSpacing: LekisSpacing.sm,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: installing ? null : onInstallZip,
                    icon: const Icon(Icons.folder_zip_outlined),
                    label: const Text(PluginStrings.installZip),
                  ),
                  OutlinedButton.icon(
                    onPressed: installing ? null : onInstallFolder,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text(PluginStrings.installFolder),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.detail,
    required this.onRetry,
  });

  final String message;
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LekisSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.danger),
            const SizedBox(height: LekisSpacing.md),
            Text(message, style: theme.textTheme.titleMedium),
            const SizedBox(height: LekisSpacing.xs),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: LekisSpacing.md),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text(PluginStrings.retry),
            ),
          ],
        ),
      ),
    );
  }
}
