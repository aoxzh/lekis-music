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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../layout/adaptive_two_pane.dart';
import '../../platform/ui_profile.dart';
import '../../shell/app_shell.dart';
import '../../theme/tokens.dart';
import '../downloads/downloads_models.dart';
import '../downloads/downloads_providers.dart';
import '../enrich/enrich_providers.dart';
import '../library/widgets/page_gutter.dart';
import '../sources/sources_providers.dart';
import 'desktop_settings_view.dart';
import 'settings_categories.dart';
import 'strings.dart';
import 'widgets/settings_widgets.dart';

export 'settings_categories.dart'
    show
        PluginsSettingsTile,
        SettingsCategory,
        SettingsCategoryPage,
        SettingsCategoryGroup;

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 宽窗口右栏显示的分类。
  SettingsCategory _selected = SettingsCategory.playback;

  void _open(SettingsCategory category) {
    if (isWideLayout(context)) {
      setState(() => _selected = category);
    } else {
      Navigator.of(context).push(SettingsCategoryPage.route(category));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideLayout(context);
    if (wide && UiProfile.current.desktopSettings) {
      return DesktopSettingsView(
        selected: _selected,
        onSelected: (c) => setState(() => _selected = c),
      );
    }
    final list = SettingsHomeList(
      selected: wide ? _selected : null,
      onOpen: _open,
    );
    return SettingsScaffold(
      title: SettingsStrings.title,
      body: !wide
          ? list
          : AdaptiveTwoPane(
              primaryFraction: 0.38,
              primary: list,
              secondary: KeyedSubtree(
                key: ValueKey(_selected),
                child: SettingsListView(children: _selected.sections),
              ),
            ),
    );
  }
}

/// 设置首页的列表本体。
class SettingsHomeList extends ConsumerWidget {
  const SettingsHomeList({super.key, required this.onOpen, this.selected});

  final ValueChanged<SettingsCategory> onOpen;

  /// 宽窗口里高亮的分类；窄窗口为 `null`。
  final SettingsCategory? selected;

  Widget _category(SettingsCategory c, {Widget? trailing}) => SettingsTile(
    key: ValueKey('settings-category-${c.name}'),
    icon: c.icon,
    title: c.title,
    subtitle: Text(c.hint, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: trailing,
    chevron: true,
    selected: selected == c,
    onTap: () => onOpen(c),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourcesProvider).value;
    final downloads = ref.watch(downloadsSummaryProvider);
    final pending = ref.watch(enrichPendingCountProvider);
    final noSources = sources != null && sources.isEmpty;

    return SettingsListView(
      children: [
        if (noSources) const SettingsSetupCard(),
        for (final group in SettingsCategoryGroup.values)
          SettingsSection(
            title: group.title,
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
                  c,
                  trailing:
                      c == SettingsCategory.organize &&
                          pending != null &&
                          pending > 0
                      ? Badge.count(count: pending)
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
      padding: const EdgeInsets.only(bottom: LekisSpacing.xl),
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
                onPressed: () =>
                    AppShell.select(context, LekisDestination.sources),
                icon: const Icon(Icons.add),
                label: const Text(SettingsStrings.setupAction),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
