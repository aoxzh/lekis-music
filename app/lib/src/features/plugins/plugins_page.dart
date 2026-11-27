// 本地插件管理页：安装、启用 / 停用、移除和打开插件设置。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';
import '../../rust/api/error.dart';
import '../../theme/tokens.dart';
import '../library/widgets/empty_state.dart';
import '../settings/widgets/settings_reveal.dart';
import '../settings/widgets/settings_widgets.dart';
import '../sources/common.dart';
import 'plugin_builtin_source_tile.dart';
import 'plugin_detail_sheet.dart';
import 'plugin_download.dart';
import 'plugin_format.dart';
import 'plugin_registry.dart';
import 'plugin_sources.dart';
import 'plugins_providers.dart';
import 'strings.dart';

enum _InstallChoice { folder, zip, link }

enum _DirectoryAction { copy, open }

class PluginsPage extends ConsumerStatefulWidget {
  const PluginsPage({super.key});

  @override
  ConsumerState<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends ConsumerState<PluginsPage> {
  final Set<String> _busy = {};
  bool _installing = false;
  bool _browsing = false;

  Future<void> _toggle(PluginInfoDto plugin, bool enabled) => _run(
    plugin.id,
    () => ref.read(pluginListProvider.notifier).setEnabled(plugin.id, enabled),
  );

  Future<void> _remove(PluginInfoDto plugin) async {
    final confirmed = await showLekisPanel<bool>(
      context,
      builder: (context) => LekisPanel(
        title: PluginStrings.removeTitle,
        body: Text(PluginStrings.removeBody(plugin.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(PluginStrings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.lekisColors.danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(PluginStrings.confirmRemove),
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

  Future<void> _chooseInstall({bool linkOnly = false}) async {
    var enteringLink = linkOnly;
    Uri? address;
    final choice = await showLekisPanel<_InstallChoice>(
      context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          void editLink(bool editing) {
            FocusScope.of(context).unfocus();
            update(() {
              enteringLink = editing;
              address = null;
            });
          }

          void back() {
            if (enteringLink && !linkOnly) {
              editLink(false);
            } else {
              Navigator.pop(dialog);
            }
          }

          void submit() {
            if (address != null) Navigator.pop(dialog, _InstallChoice.link);
          }

          return PopScope<_InstallChoice>(
            canPop: !enteringLink || linkOnly,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && enteringLink && !linkOnly) editLink(false);
            },
            child: LekisPanel(
              title: enteringLink
                  ? PluginStrings.installLink
                  : PluginStrings.install,
              subtitle: enteringLink ? null : PluginStrings.installHint,
              body: AnimatedSize(
                alignment: Alignment.topCenter,
                curve: Curves.easeOutCubic,
                duration:
                    lekisPanelMotion(context).reverseDuration ?? Duration.zero,
                child: enteringLink
                    ? TextField(
                        autofocus: true,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'HTTPS ZIP URL',
                        ),
                        onChanged: (value) =>
                            update(() => address = pluginPackageUri(value)),
                        onSubmitted: (_) => submit(),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SettingsTile(
                            icon: Icons.link_rounded,
                            title: PluginStrings.installLink,
                            chevron: true,
                            onTap: () => editLink(true),
                          ),
                          SettingsTile(
                            icon: Icons.folder_open_outlined,
                            title: PluginStrings.installFolder,
                            onTap: () =>
                                Navigator.pop(dialog, _InstallChoice.folder),
                          ),
                          SettingsTile(
                            icon: Icons.folder_zip_outlined,
                            title: PluginStrings.installZip,
                            onTap: () =>
                                Navigator.pop(dialog, _InstallChoice.zip),
                          ),
                        ],
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: back,
                  child: Text(
                    enteringLink && !linkOnly
                        ? MaterialLocalizations.of(context).backButtonTooltip
                        : PluginStrings.cancel,
                  ),
                ),
                if (enteringLink)
                  FilledButton(
                    onPressed: address == null ? null : submit,
                    child: Text(PluginStrings.install),
                  ),
              ],
            ),
          );
        },
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _InstallChoice.folder:
        await _installFolder();
      case _InstallChoice.zip:
        await _installZip();
      case _InstallChoice.link:
        await _installRemote(address!);
      case null:
        break;
    }
  }

  Future<void> _confirmCatalogInstall(RegistryPlugin plugin) async {
    final confirmed = await showLekisPanel<bool>(
      context,
      builder: (dialog) => LekisPanel(
        title: PluginStrings.downloadInstall,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${plugin.name} · v${plugin.version}'),
            Text(plugin.id),
            const SizedBox(height: LekisSpacing.sm),
            SelectableText(plugin.package.toString()),
            const SizedBox(height: LekisSpacing.md),
            Text(PluginStrings.providerNotice),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(PluginStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(PluginStrings.downloadInstall),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _installRemote(plugin.package, expectedSha256: plugin.sha256);
  }

  Future<void> _installRemote(Uri uri, {String? expectedSha256}) async {
    setState(() => _installing = true);
    try {
      await installRemotePluginPackage(
        uri,
        expectedSha256: expectedSha256,
        install: (path) async {
          if (mounted) await _installFromPath(path);
        },
      );
    } catch (error) {
      _showInstallError(error);
    } finally {
      if (mounted) setState(() => _installing = false);
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
      await _installFromPath(path);
    } catch (error) {
      _showInstallError(error);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _installFromPath(String path) async {
    final plugin = await ref.read(pluginListProvider.notifier).install(path);
    if (mounted) {
      showFeatureSnack(context, '${PluginStrings.installed}：${plugin.name}');
    }
  }

  void _showInstallError(Object error) {
    if (!mounted) return;
    final kind = coreErrorKind(error);
    final message = kind == ErrorKind.invalidArgument
        ? PluginStrings.installInvalid
        : '${PluginStrings.installFailed}：${error is FormatException ? error.message : describeCoreError(error)}';
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
    final action = await showLekisPanel<_DirectoryAction>(
      context,
      builder: (context) => LekisPanel(
        title: PluginStrings.pluginDir,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(PluginStrings.pluginDirHint),
            const SizedBox(height: LekisSpacing.md),
            SelectableText(path),
          ],
        ),
        actions: [
          if (Platform.isWindows || Platform.isLinux)
            TextButton(
              onPressed: () => Navigator.of(context).pop(_DirectoryAction.open),
              child: Text(PluginStrings.openInExplorer),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_DirectoryAction.copy),
            child: Text(PluginStrings.copyPath),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(PluginStrings.close),
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

  Future<void> _addSource() async {
    final controller = TextEditingController();
    final field = GlobalKey<FormFieldState<String>>();
    final raw = await showLekisPanel<String>(
      context,
      builder: (dialog) {
        void submit() {
          if (field.currentState!.validate()) {
            Navigator.of(dialog).pop(controller.text);
          }
        }

        return LekisPanel(
          title: PluginStrings.addSource,
          body: TextFormField(
            key: field,
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            autocorrect: false,
            autovalidateMode: AutovalidateMode.onUserInteractionIfError,
            validator: (value) {
              final url = normalizePluginSourceUrl(value ?? '');
              final sources = ref.read(pluginSourcesProvider).value ?? [];
              return url == null ||
                      url == defaultPluginSourceUrl ||
                      sources.any((s) => s.url == url)
                  ? PluginStrings.sourceInvalid
                  : null;
            },
            decoration: InputDecoration(
              labelText: PluginStrings.sourceUrlLabel,
              hintText: PluginStrings.sourceUrlHint,
            ),
            onFieldSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: Text(PluginStrings.cancel),
            ),
            FilledButton(
              onPressed: submit,
              child: Text(PluginStrings.addSource),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (raw == null || !mounted) return;
    final added = await ref.read(pluginSourcesProvider.notifier).add(raw);
    if (!mounted) return;
    showFeatureSnack(
      context,
      added ? PluginStrings.sourceAdded : PluginStrings.sourceInvalid,
    );
  }

  Future<void> _removeSource(String url) async {
    await ref.read(pluginSourcesProvider.notifier).remove(url);
    if (!mounted) return;
    showFeatureSnack(context, PluginStrings.sourceRemoved);
  }

  List<Widget> _catalogRows(
    AsyncValue<List<RegistryPlugin>> catalog,
    AsyncValue<List<PluginInfoDto>> installed, {
    required VoidCallback retry,
    String? emptyLabel,
    String? errorLabel,
  }) {
    return catalog.when(
      skipLoadingOnRefresh: false,
      loading: () => [
        SettingsTile(
          icon: Icons.extension_outlined,
          title: PluginStrings.catalogLoading,
          trailing: const SizedBox.square(
            dimension: LekisSpacing.lg,
            child: CircularProgressIndicator(strokeWidth: LekisSpacing.xxs),
          ),
        ),
      ],
      error: (error, _) => [
        SettingsTile(
          icon: Icons.error_outline_rounded,
          title: errorLabel ?? PluginStrings.catalogFailed,
          subtitle: Text(error.toString()),
          trailing: IconButton(
            tooltip: PluginStrings.retry,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: retry,
          ),
        ),
      ],
      data: (entries) => [
        if (entries.isEmpty)
          SettingsTile(
            icon: Icons.extension_outlined,
            title: emptyLabel ?? PluginStrings.catalogEmpty,
          ),
        for (final entry in entries)
          _catalogRow(
            entry,
            installed:
                installed.value?.any((item) => item.id == entry.id) ?? false,
            available: installed.hasValue && !_installing,
          ),
      ],
    );
  }

  List<Widget> _customSourceSections(
    AsyncValue<List<PluginInfoDto>> installed,
  ) {
    final sources = ref.watch(pluginSourcesProvider).value;
    return [
      for (final source in sources ?? const <PluginSource>[])
        if (!source.builtIn)
          SettingsSection(
            title: source.url,
            trailing: IconButton(
              tooltip: PluginStrings.removeSource,
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              onPressed: () => _removeSource(source.url),
            ),
            children: _catalogRows(
              ref.watch(pluginSourceCatalogProvider(source.url)),
              installed,
              retry: () =>
                  ref.invalidate(pluginSourceCatalogProvider(source.url)),
              emptyLabel: PluginStrings.sourceEmpty,
              errorLabel: PluginStrings.sourceLoadFailed,
            ),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final plugins = ref.watch(pluginListProvider);
    // Watched up front so the switch is known before the catalog is browsed.
    final builtinEnabled =
        ref.watch(pluginBuiltinSourceEnabledProvider).value ?? false;
    return SettingsScaffold(
      title: PluginStrings.title,
      actions: [
        SettingsReveal.control(
          context,
          IconButton(
            key: const ValueKey('plugins.refresh'),
            tooltip: PluginStrings.refresh,
            onPressed: plugins.isLoading
                ? null
                : () => ref.read(pluginListProvider.notifier).reload(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        SettingsReveal.control(
          context,
          IconButton.filledTonal(
            key: const ValueKey('plugins.install'),
            tooltip: PluginStrings.install,
            onPressed: _installing ? null : _chooseInstall,
            icon: const Icon(Icons.add),
          ),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_installing)
            const LinearProgressIndicator(minHeight: LekisSpacing.xxs),
          Expanded(
            child: SettingsListView(
              children: [
                SettingsGroup(
                  children: [
                    if (!_browsing)
                      SettingsTile(
                        key: const ValueKey('plugins.browse'),
                        icon: Icons.extension_outlined,
                        title: PluginStrings.browse,
                        chevron: true,
                        onTap: () => setState(() => _browsing = true),
                      ),
                    SettingsTile(
                      key: const ValueKey('plugins.directory'),
                      icon: Icons.folder_outlined,
                      title: PluginStrings.pluginDir,
                      chevron: true,
                      onTap: _showDirectory,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    settingsRowInset,
                    LekisSpacing.sm,
                    settingsRowInset,
                    LekisSpacing.xl,
                  ),
                  child: Text(
                    PluginStrings.providerNotice,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (_browsing) ...[
                  SettingsSection(
                    title: PluginStrings.defaultSource,
                    children: [
                      const PluginBuiltinSourceTile(
                        key: ValueKey('plugins.builtin-source'),
                      ),
                      // Switched off: the built-in catalog is not fetched.
                      if (builtinEnabled)
                        ..._catalogRows(
                          ref.watch(pluginRegistryProvider),
                          plugins,
                          retry: () => ref.invalidate(pluginRegistryProvider),
                        ),
                    ],
                  ),
                  ..._customSourceSections(plugins),
                  Padding(
                    padding: const EdgeInsets.only(bottom: LekisSpacing.xl),
                    child: SettingsGroup(
                      children: [
                        SettingsTile(
                          key: const ValueKey('plugins.add-source'),
                          icon: Icons.add_link_rounded,
                          title: PluginStrings.addSource,
                          chevron: true,
                          onTap: _installing ? null : _addSource,
                        ),
                      ],
                    ),
                  ),
                ],
                plugins.when(
                  skipLoadingOnReload: true,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => LekisEmptyState(
                    title: PluginStrings.loadFailed,
                    message: describeCoreError(error),
                    action: FilledButton.tonalIcon(
                      onPressed: () =>
                          ref.read(pluginListProvider.notifier).reload(),
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(PluginStrings.retry),
                    ),
                  ),
                  data: (list) => list.isEmpty
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SettingsSectionHeader(PluginStrings.emptyTitle),
                            SettingsGroup(
                              children: [
                                SettingsTile(
                                  icon: Icons.folder_zip_outlined,
                                  title: PluginStrings.installZip,
                                  chevron: true,
                                  onTap: _installing ? null : _installZip,
                                ),
                                SettingsTile(
                                  icon: Icons.link_rounded,
                                  title: PluginStrings.installLink,
                                  chevron: true,
                                  onTap: _installing
                                      ? null
                                      : () => _chooseInstall(linkOnly: true),
                                ),
                                SettingsTile(
                                  icon: Icons.folder_open_outlined,
                                  title: PluginStrings.installFolder,
                                  chevron: true,
                                  onTap: _installing ? null : _installFolder,
                                ),
                              ],
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: settingsRowInset,
                                vertical: LekisSpacing.sm,
                              ),
                              child: Text(
                                PluginStrings.sourceHint,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        )
                      : SettingsSection(
                          title: PluginStrings.manageTitle,
                          children: [
                            for (final plugin in list)
                              _PluginRow(
                                key: ValueKey(plugin.id),
                                plugin: plugin,
                                busy: _busy.contains(plugin.id),
                                onToggle: (enabled) => _toggle(plugin, enabled),
                                onRemove: () => _remove(plugin),
                                onOpen: () async {
                                  await showPluginDetailSheet(context, plugin);
                                  if (mounted) {
                                    await ref
                                        .read(pluginListProvider.notifier)
                                        .reload();
                                  }
                                },
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _catalogRow(
    RegistryPlugin plugin, {
    required bool installed,
    required bool available,
  }) {
    return SettingsTile(
      icon: Icons.extension_outlined,
      title: plugin.name,
      annotation: installed ? PluginStrings.installed : null,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'v${plugin.version}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (plugin.description.isNotEmpty) ...[
            const SizedBox(height: LekisSpacing.xs),
            Text(plugin.description),
          ],
          if (!installed) ...[
            const SizedBox(height: LekisSpacing.sm),
            OutlinedButton(
              onPressed: available
                  ? () => _confirmCatalogInstall(plugin)
                  : null,
              child: Text(PluginStrings.downloadInstall),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一个插件占分组里的一行：名称、版本 / 类型、ID、权限或清单错误；
/// 右侧是启用开关和移除按钮。点整行打开详情与设置。
class _PluginRow extends StatelessWidget {
  const _PluginRow({
    super.key,
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
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.lg,
          vertical: LekisSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingsLeadingIcon(
              hasError ? Icons.error_outline : Icons.extension_outlined,
              color: hasError ? colors.danger : null,
            ),
            const SizedBox(width: LekisSpacing.lg),
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
                          style: theme.textTheme.bodyLarge,
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
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    plugin.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: LekisSpacing.xs),
                  if (hasError)
                    _InlineError(message: plugin.error!)
                  else
                    Text(
                      pluginPermissionSummary(plugin.permissions),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            const SizedBox(width: LekisSpacing.sm),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(LekisSpacing.md),
                child: SizedBox.square(
                  dimension: LekisSpacing.lg,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              Switch(
                value: plugin.enabled,
                onChanged: hasError ? null : onToggle,
              ),
            settingsAlignTrailing(
              IconButton(
                tooltip: PluginStrings.remove,
                onPressed: busy ? null : onRemove,
                color: colors.onSurfaceVariant,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ),
          ],
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
      width: double.infinity,
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
