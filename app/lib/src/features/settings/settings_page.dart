// 设置首页：只放普通用户需要的几行，其余都在二级页面里。
//
//   音乐    音源 · 下载 · 整理资料库
//   通用    播放 · 外观 · 歌词
//   更多    高级 · 关于
//
// 手机 / 窄窗口：单列，点行推入二级页面。
// 宽窗口：左边是这个列表，右边直接显示选中分类的内容（列表 + 详情）。
// 桌面（[UiProfile.desktopSettings]）宽窗口：Windows 11 设置式的导航 + 详情，
// 见 desktop_settings_view.dart。
//
// 分类和分组都来自 [SettingsCategory]；加分类只改那个枚举。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../layout/adaptive_two_pane.dart';
import '../../platform/ui_profile.dart';
import '../../shell/app_shell.dart';
import '../../theme/tokens.dart';
import '../downloads/downloads_models.dart';
import '../downloads/downloads_providers.dart';
import '../enrich/enrich_providers.dart';
import '../library/widgets/page_gutter.dart';
import '../sources/sources_providers.dart';
import 'app_updater_provider.dart';
import 'desktop_settings_view.dart';
import 'settings_categories.dart';
import 'settings_search.dart';
import 'strings.dart';
import 'widgets/settings_widgets.dart';

export 'settings_categories.dart'
    show
        PluginsSettingsTile,
        SettingsCategory,
        SettingsCategoryPage,
        SettingsCategoryGroup;

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// 宽窗口右栏显示的分类。
  SettingsCategory _selected = SettingsCategory.playback;
  SettingsSearchItem? _target;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(appUpdaterProvider.notifier).checkOncePerDay());
      }
    });
  }

  void _open(SettingsCategory category, {SettingsSearchItem? target}) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (isWideLayout(context)) {
      setState(() {
        _selected = category;
        _target = target;
      });
    } else {
      Navigator.of(context)
          .push(SettingsCategoryPage.route(category, target: target));
    }
  }

  void _openSearch(SettingsSearchItem item) {
    if (item.inPlugins) {
      FocusManager.instance.primaryFocus?.unfocus();
      Navigator.of(context).push(item.pluginRoute());
    } else {
      _open(item.category, target: item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideLayout(context);
    if (wide && UiProfile.current.desktopSettings) {
      return DesktopSettingsView(
        selected: _selected,
        onSelected: _open,
        target: _target,
        onSearchSelected: _openSearch,
      );
    }
    final list = SettingsHomeList(
      selected: wide ? _selected : null,
      onOpen: _open,
      onSearchSelected: _openSearch,
    );
    return SettingsScaffold(
      title: context.l10n.settingsTitle,
      body: !wide
          ? list
          : AdaptiveTwoPane(
              primaryFraction: 0.38,
              primary: list,
              secondary: KeyedSubtree(
                key: ValueKey(_selected),
                child: _selected.detail(_target),
              ),
            ),
    );
  }
}

/// 设置首页的列表本体。
class SettingsHomeList extends ConsumerStatefulWidget {
  const SettingsHomeList({
    super.key,
    required this.onOpen,
    required this.onSearchSelected,
    this.selected,
  });

  final ValueChanged<SettingsCategory> onOpen;
  final ValueChanged<SettingsSearchItem> onSearchSelected;

  /// 宽窗口里高亮的分类；窄窗口为 `null`。
  final SettingsCategory? selected;
  @override
  ConsumerState<SettingsHomeList> createState() => _SettingsHomeListState();
}

class _SettingsHomeListState extends ConsumerState<SettingsHomeList> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _category(
    BuildContext context,
    SettingsCategory c, {
    Widget? trailing,
  }) => SettingsTile(
    key: ValueKey('settings-category-${c.name}'),
    icon: c.icon,
    title: c.titleOf(context),
    subtitle: Text(c.hint, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: trailing,
    chevron: true,
    selected: widget.selected == c,
    onTap: () => widget.onOpen(c),
  );

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final items = searchSettings(ref, query);
    final categories = SettingsCategory.values.where((c) => c.matches(query));
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pageGutterOf(context)),
          child: TextField(
            key: const ValueKey('settings-mobile-search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) {
              if (items.isNotEmpty) {
                widget.onSearchSelected(items.first);
              } else if (categories.isNotEmpty) {
                widget.onOpen(categories.first);
              }
            },
            decoration: InputDecoration(
              hintText: context.l10n.searchSettingsHint,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: context.l10n.pick('清除', 'Clear'),
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
        ),
        Expanded(
          child: query.isNotEmpty
              ? SettingsListView(
                  children: [
                    if (items.isEmpty && categories.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(settingsRowInset),
                        child: Text(
                          SettingsStrings.searchEmpty,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    for (final item in items)
                      SettingsSearchRow(
                        item: item,
                        onTap: () => widget.onSearchSelected(item),
                      ),
                    for (final category in categories)
                      _category(context, category),
                  ],
                )
              : _home(context),
        ),
      ],
    );
  }

  Widget _home(BuildContext context) {
    final sources = ref.watch(sourcesProvider).value;
    final downloads = ref.watch(downloadsSummaryProvider);
    final pending = ref.watch(enrichPendingCountProvider);
    final updateState = ref.watch(appUpdaterProvider);
    final hasUpdate =
        updateState.phase == AppUpdaterPhase.available ||
        updateState.phase == AppUpdaterPhase.ready;
    final noSources = sources != null && sources.isEmpty;
    return SettingsListView(
      children: [
        if (noSources) const SettingsSetupCard(),
        for (final group in SettingsCategoryGroup.values)
          SettingsSection(
            title: group.titleOf(context),
            children: [
              // 音源和下载不是设置分类，而是去对应页面的入口，排在音乐组最前。
              if (group == SettingsCategoryGroup.music) ...[
                SettingsTile(
                  key: const ValueKey('settings-sources'),
                  icon: Icons.storage_outlined,
                  title: SettingsStrings.sources,
                  subtitle: Text(
                    sources == null
                        ? SettingsStrings.sourcesHint
                        : sources.isEmpty
                        ? SettingsStrings.sourcesNone
                        : SettingsStrings.sourcesCount(sources.length),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  chevron: true,
                  onTap: () =>
                      AppShell.select(context, LekisDestination.sources),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
              ],
              for (final c in SettingsCategory.inGroup(group))
                _category(
                  context,
                  c,
                  trailing:
                      c == SettingsCategory.organize &&
                          pending != null &&
                          pending > 0
                      ? Badge.count(count: pending)
                      : c == SettingsCategory.about && hasUpdate
                      ? const Badge()
                      : null,
                ),
            ],
          ),
      ],
    );
  }
}

/// 还没有任何音源时，首页最上面的引导卡片。
class SettingsSetupCard extends StatelessWidget {
  const SettingsSetupCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        UiProfile.current.desktopSettings ? 0 : settingsRowInset,
        0,
        UiProfile.current.desktopSettings ? 0 : settingsRowInset,
        LekisSpacing.xl,
      ),
      child: DecoratedBox(
        decoration: UiProfile.current.desktopSettings
            ? settingsCardDecoration(context)
            : settingsPanelDecoration(context),
        child: Padding(
          padding: const EdgeInsets.all(LekisSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.library_music_outlined, color: colors.accent),
                  const SizedBox(width: LekisSpacing.md),
                  Expanded(
                    child: Text(
                      SettingsStrings.setupTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: LekisSpacing.sm),
              Text(SettingsStrings.setupBody, style: theme.textTheme.bodySmall),
              const SizedBox(height: LekisSpacing.md),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, LekisSizes.touchTargetMin),
                ),
                onPressed: () => AppShell.openAddSource(context),
                icon: const Icon(Icons.add),
                label: Text(SettingsStrings.setupAction),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
