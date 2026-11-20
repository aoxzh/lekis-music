// Desktop settings (Windows / macOS / Linux, wide windows): the Windows 11
// Settings layout.
//
//   ┌──────────────────┬───────────────────────────────────────┐
//   │ 设置             │ 播放                                  │
//   │ [查找设置   ]    │                                       │
//   │ 音乐             │ 播放                                  │
//   │  ▍音源           │ ┌───────────────────────────────────┐ │
//   │   下载           │ │ 输出设备             [默认    ⌄]  │ │
//   │   整理资料库     │ ├───────────────────────────────────┤ │
//   │ 通用             │ │ 无缝播放                 开 (●)   │ │
//   │   播放  ◀        │ └───────────────────────────────────┘ │
//   │   …              │                                       │
//   └──────────────────┴───────────────────────────────────────┘
//
// Left: title, search box (Ctrl+F / ⌘F), the category list grouped like the
// phone home page (音乐 / 通用 / 更多). Right: the selected category's title
// and its sections, which render as Windows-style cards with dropdowns and
// labelled toggles (see settings_widgets.dart). Every row is reachable with
// Tab / arrow keys and shows hover and focus states.
//
// Categories come from [SettingsCategory]; adding one there adds it here,
// to the phone home list and to the search.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../shell/app_shell.dart';
import '../../theme/tokens.dart';
import '../downloads/downloads_providers.dart';
import '../enrich/enrich_providers.dart';
import '../library/widgets/page_gutter.dart';
import '../sources/sources_providers.dart';
import 'settings_categories.dart';
import 'settings_page.dart' show SettingsSetupCard;
import 'strings.dart';

/// Width of the category list.
const double desktopSettingsNavWidth = 288;

/// Widest the detail column gets (Windows Settings caps its cards too).
const double desktopSettingsDetailMaxWidth = 1000;

class DesktopSettingsView extends ConsumerStatefulWidget {
  const DesktopSettingsView({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final SettingsCategory selected;
  final ValueChanged<SettingsCategory> onSelected;

  static const Key searchKey = ValueKey('settings-search');

  @override
  ConsumerState<DesktopSettingsView> createState() =>
      _DesktopSettingsViewState();
}

class _DesktopSettingsViewState extends ConsumerState<DesktopSettingsView> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'settings.search');

  String get _query => _search.text.trim().toLowerCase();

  @override
  void initState() {
    super.initState();
    _search.addListener(_onQueryChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onQueryChanged() => setState(() {});

  /// Ctrl+F (⌘F on macOS) focuses the search box while this page is the
  /// visible tab and nothing is pushed over it.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyF) {
      return false;
    }
    final keys = HardwareKeyboard.instance;
    if (!(keys.isControlPressed || keys.isMetaPressed) || !mounted) {
      return false;
    }
    if (!TickerMode.valuesOf(context).enabled) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
    return true;
  }

  List<SettingsCategory> _matches(String query) => [
    for (final c in SettingsCategory.values)
      if (c.matches(query)) c,
  ];

  void _openFirstMatch() {
    final first = _matches(_query).firstOrNull;
    if (first != null) widget.onSelected(first);
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: SafeArea(
      bottom: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: desktopSettingsNavWidth, child: _nav(context)),
          Expanded(child: _detail(context)),
        ],
      ),
    ),
  );

  Widget _nav(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final sources = ref.watch(sourcesProvider).value;
    final downloads = ref.watch(downloadsSummaryProvider);
    final pending = ref.watch(enrichPendingCountProvider);
    final query = _query;
    bool linkMatches(String title, String hint) =>
        query.isEmpty ||
        title.toLowerCase().contains(query) ||
        hint.toLowerCase().contains(query);

    final groups = <Widget>[];
    for (final group in SettingsCategoryGroup.values) {
      final items = <Widget>[
        if (group == SettingsCategoryGroup.music) ...[
          if (linkMatches(SettingsStrings.sources, SettingsStrings.sourcesHint))
            _NavItem(
              key: const ValueKey('settings-sources'),
              icon: Icons.storage_outlined,
              title: SettingsStrings.sources,
              tooltip: sources == null || sources.isEmpty
                  ? SettingsStrings.sourcesHint
                  : SettingsStrings.sourcesCount(sources.length),
              external: true,
              onTap: () => AppShell.select(context, LekisDestination.sources),
            ),
          if (linkMatches(
            SettingsStrings.downloads,
            SettingsStrings.downloadsHint,
          ))
            _NavItem(
              key: const ValueKey('settings-downloads'),
              icon: Icons.download_for_offline_outlined,
              title: SettingsStrings.downloads,
              tooltip: SettingsStrings.downloadsHint,
              external: true,
              trailing: downloads.activeCount > 0
                  ? const SizedBox.square(
                      dimension: LekisSpacing.md,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: () => openDownloads(context),
            ),
        ],
        for (final c in SettingsCategory.inGroup(group))
          if (c.matches(query))
            _NavItem(
              key: ValueKey('settings-category-${c.name}'),
              icon: c.icon,
              title: c.title,
              tooltip: c.hint,
              selected: c == widget.selected,
              trailing:
                  c == SettingsCategory.organize &&
                      pending != null &&
                      pending > 0
                  ? Badge.count(count: pending)
                  : null,
              onTap: () => widget.onSelected(c),
            ),
      ];
      if (items.isEmpty) continue;
      groups.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LekisSpacing.md,
            LekisSpacing.lg,
            LekisSpacing.md,
            LekisSpacing.xs,
          ),
          child: Semantics(
            header: true,
            child: Text(
              group.title,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
      groups.addAll(items);
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        pageGutterOf(context) - LekisSpacing.md,
        0,
        LekisSpacing.sm,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LekisSpacing.md,
              LekisSpacing.xl,
              LekisSpacing.md,
              LekisSpacing.lg,
            ),
            child: Semantics(
              header: true,
              child: Text(
                SettingsStrings.title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.xs),
            child: TextField(
              key: DesktopSettingsView.searchKey,
              controller: _search,
              focusNode: _searchFocus,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _openFirstMatch(),
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                hintText: SettingsStrings.searchHint,
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除',
                        iconSize: 16,
                        onPressed: _search.clear,
                        icon: const Icon(Icons.close_rounded),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(LekisRadius.xs),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(LekisRadius.xs),
                  borderSide: BorderSide(color: colors.outline),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(LekisRadius.xs),
                  borderSide: BorderSide(color: colors.accent, width: 1.5),
                ),
              ),
            ),
          ),
          Expanded(
            child: groups.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(LekisSpacing.md),
                    child: Text(
                      SettingsStrings.searchEmpty,
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : FocusTraversalGroup(
                    child: ListView(
                      padding: EdgeInsets.only(
                        bottom: scrollEndPadding(context),
                      ),
                      children: groups,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context) {
    final theme = Theme.of(context);
    final sources = ref.watch(sourcesProvider).value;
    final noSources = sources != null && sources.isEmpty;
    final category = widget.selected;
    final gutter = pageGutterOf(context);
    return KeyedSubtree(
      key: ValueKey(category),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              LekisSpacing.xl,
              gutter,
              LekisSpacing.lg,
            ),
            child: Semantics(
              header: true,
              child: Text(
                category.title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Expanded(
            child: FocusTraversalGroup(
              child: ListView(
                key: PageStorageKey('settings-detail-${category.name}'),
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  0,
                  gutter,
                  scrollEndPadding(context),
                ),
                children: [
                  Align(
                    alignment: AlignmentDirectional.topStart,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: desktopSettingsDetailMaxWidth,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (noSources) const SettingsSetupCard(),
                          ...category.sections,
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of the category list: Windows 11 navigation item (accent pill on
/// the selected row, subtle fill, hover / focus highlight, hint as tooltip).
class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.tooltip,
    this.selected = false,
    this.external = false,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? tooltip;
  final VoidCallback onTap;
  final bool selected;

  /// Opens another page (sources, downloads) instead of the detail pane.
  final bool external;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final radius = BorderRadius.circular(LekisRadius.xs);
    Widget item = Material(
      color: selected
          ? theme.colorScheme.onSurface.withValues(alpha: 0.07)
          : Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: SizedBox(
          height: LekisSpacing.xxl + LekisSpacing.sm,
          child: Row(
            children: [
              AnimatedContainer(
                duration: LekisMotion.fast,
                width: 3,
                height: selected ? LekisSpacing.lg : 0,
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(LekisRadius.pill),
                ),
              ),
              const SizedBox(width: LekisSpacing.sm + 1),
              Icon(
                icon,
                size: LekisSpacing.lg + LekisSpacing.xxs,
                color: selected ? colors.accent : colors.onSurfaceVariant,
              ),
              const SizedBox(width: LekisSpacing.md),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : null,
                  ),
                ),
              ),
              if (trailing != null) ...[
                trailing!,
                const SizedBox(width: LekisSpacing.sm),
              ],
              if (external)
                Padding(
                  padding: const EdgeInsets.only(right: LekisSpacing.sm),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: LekisSpacing.lg,
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (tooltip != null) {
      item = Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: item,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Semantics(selected: selected, button: true, child: item),
    );
  }
}
