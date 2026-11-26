import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/cover_flow_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/scoped_library_view.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/search/search_page.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/action_menu.dart';
import 'package:material_ui/material_ui.dart';

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(effectiveLibrarySourceProvider);
    final segment = ref.watch(librarySegmentProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LibraryHeader(),
            Expanded(
              child: ScopedLibraryView(
                key: ValueKey((source, segment)),
                scope: source,
                segment: segment,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LibraryHeader extends ConsumerWidget {
  const LibraryHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(effectiveLibrarySourceProvider);
    final plugins = ref.watch(librarySourcePluginsProvider);
    final segment = ref.watch(librarySegmentProvider);
    final l10n = context.l10n;
    final labels = <LibraryScope, String>{
      const LibraryScope.local(): l10n.pick('本地资料库', 'Local Library'),
      const LibraryScope.nas(): 'NAS',
      for (final plugin in plugins) LibraryScope.plugin(plugin.id): plugin.name,
    };
    final categories = {
      LibrarySegment.albums: l10n.segAlbums,
      LibrarySegment.artists: l10n.segArtists,
      LibrarySegment.songs: l10n.segSongs,
      LibrarySegment.genres: l10n.segGenres,
      LibrarySegment.playlists: l10n.segPlaylists,
      LibrarySegment.liked: l10n.segLiked,
      LibrarySegment.folders: l10n.segFolders,
    };
    final titleStyle = Theme.of(context).textTheme.headlineMedium
        ?.copyWith(fontWeight: FontWeight.w700);
    final title = _SourceTitle(
      scope: source,
      labels: labels,
      style: titleStyle,
      onSelected: (scope) {
        if (scope.pluginId != null &&
            !ref
                .read(librarySourcePluginsProvider)
                .any((plugin) => plugin.id == scope.pluginId)) {
          return;
        }
        ref.read(librarySourceProvider.notifier).set(scope);
      },
    );
    final pluginId = source.pluginId;
    final tools = Row(
      key: const ValueKey('library-header-actions'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pluginId != null)
          IconButton(
            tooltip: l10n.pick('搜索在线音乐', 'Search online music'),
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (context) => Scaffold(
                  appBar: AppBar(title: Text(labels[source] ?? pluginId)),
                  body: SearchPage(pluginId: pluginId),
                ),
              ),
            ),
          ),
        if (segment == LibrarySegment.albums || segment == LibrarySegment.songs)
          _SortMenu(albums: segment == LibrarySegment.albums),
        if (segment == LibrarySegment.albums) const _AlbumViewModeMenu(),
        if (segment == LibrarySegment.albums)
          IconButton(
            tooltip: l10n.coverFlow,
            icon: const Icon(Icons.view_carousel_rounded),
            onPressed: () =>
                Navigator.of(context).push(CoverFlowPage.route(scope: source)),
          ),
      ],
    );
    void select(LibrarySegment segment) =>
        ref.read(librarySegmentProvider.notifier).set(segment);

    final gutter = pageGutterOf(context);
    return Padding(
      padding: const EdgeInsets.only(
        top: LekisSpacing.lg,
        bottom: LekisSpacing.md,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          double widthOf(String label, TextStyle? style) {
            final painter = TextPainter(
              text: TextSpan(text: label, style: style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final width = painter.width;
            painter.dispose();
            return width;
          }

          final theme = Theme.of(context);
          final categoryStyle =
              theme.segmentedButtonTheme.style?.textStyle?.resolve({
                WidgetState.selected,
              }) ??
              theme.textTheme.labelLarge;
          final widestLabel = categories.values
              .map((label) => widthOf(label, categoryStyle))
              .reduce((first, second) => first > second ? first : second);
          final categoryWidth =
              categories.length * (widestLabel + 2 * LekisSpacing.sm);
          final available = constraints.maxWidth - 2 * gutter;
          final titleWidth =
              widthOf(l10n.navLibrary, titleStyle) + kMinInteractiveDimension;
          final toolsWidth = tools.children.length * kMinInteractiveDimension;
          if (available >=
              titleWidth + categoryWidth + toolsWidth + 2 * LekisSpacing.lg) {
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: title,
                    ),
                  ),
                  const SizedBox(width: LekisSpacing.lg),
                  SegmentedButton<LibrarySegment>(
                    key: const ValueKey('library-segments'),
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LekisSpacing.sm,
                      ),
                    ),
                    segments: [
                      for (final entry in categories.entries)
                        ButtonSegment(
                          value: entry.key,
                          label: Text(entry.value),
                        ),
                    ],
                    selected: {segment},
                    onSelectionChanged: (values) => select(values.first),
                  ),
                  const SizedBox(width: LekisSpacing.sm),
                  tools,
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: gutter),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [title, tools],
                ),
              ),
              const SizedBox(height: LekisSpacing.md),
              _CategoryStrip(
                key: const ValueKey('library-category-select'),
                categories: categories,
                selected: segment,
                gutter: gutter,
                onSelected: select,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SourceTitle extends StatelessWidget {
  const _SourceTitle({
    required this.scope,
    required this.labels,
    required this.style,
    required this.onSelected,
  });

  final LibraryScope scope;
  final Map<LibraryScope, String> labels;
  final TextStyle? style;
  final ValueChanged<LibraryScope> onSelected;

  @override
  Widget build(BuildContext context) {
    final tooltip = context.l10n.pick('切换资料库来源', 'Switch library source');
    final current = labels[scope] ?? scope.pluginId ?? '';
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            current,
            key: const ValueKey('library-title'),
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Icon(Icons.expand_more_rounded),
      ],
    );
    return Semantics(
      key: const ValueKey('library-source-select'),
      header: true,
      child: LekisActionMenuButton<LibraryScope>(
        title: tooltip,
        tooltip: tooltip,
        onSelected: onSelected,
        actions: () => [
          for (final entry in labels.entries)
            LekisMenuAction(
              entry.key,
              switch (entry.key.kind) {
                LibraryScopeKind.local => Icons.library_music_outlined,
                LibraryScopeKind.nas => Icons.dns_outlined,
                LibraryScopeKind.plugin => Icons.extension_outlined,
              },
              entry.value,
              selected: entry.key == scope,
            ),
        ],
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          child: title,
        ),
      ),
    );
  }
}

class _CategoryStrip extends StatefulWidget {
  const _CategoryStrip({
    super.key,
    required this.categories,
    required this.selected,
    required this.gutter,
    required this.onSelected,
  });

  final Map<LibrarySegment, String> categories;
  final LibrarySegment selected;
  final double gutter;
  final ValueChanged<LibrarySegment> onSelected;

  @override
  State<_CategoryStrip> createState() => _CategoryStripState();
}

class _CategoryStripState extends State<_CategoryStrip> {
  final _keys = {
    for (final segment in LibrarySegment.values) segment: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(false));
  }

  @override
  void didUpdateWidget(_CategoryStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(true));
    }
  }

  void _reveal(bool animate) {
    final chip = _keys[widget.selected]?.currentContext;
    if (!mounted || chip == null || !chip.mounted) return;
    Scrollable.ensureVisible(
      chip,
      alignment: 0.5,
      duration: animate && !MediaQuery.disableAnimationsOf(context)
          ? LekisMotion.fast
          : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.l10n.pick('资料库分类', 'Library category'),
    container: true,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: widget.gutter),
      child: Row(
        children: [
          for (final (index, entry) in widget.categories.entries.indexed) ...[
            if (index > 0) const SizedBox(width: LekisSpacing.sm),
            ChoiceChip(
              key: _keys[entry.key],
              label: Text(entry.value),
              selected: entry.key == widget.selected,
              onSelected: (_) => widget.onSelected(entry.key),
            ),
          ],
        ],
      ),
    ),
  );
}

class _AlbumViewModeMenu extends ConsumerWidget {
  const _AlbumViewModeMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(albumViewModeProvider);
    final l10n = context.l10n;
    String label(AlbumViewMode mode) => switch (mode) {
      AlbumViewMode.grid => l10n.pick('标准网格', 'Standard Grid'),
      AlbumViewMode.compactGrid => l10n.pick('紧凑网格', 'Compact Grid'),
      AlbumViewMode.list => l10n.pick('高效列表', 'Compact List'),
    };
    IconData iconOf(AlbumViewMode mode) => switch (mode) {
      AlbumViewMode.grid => Icons.grid_view_rounded,
      AlbumViewMode.compactGrid => Icons.apps_rounded,
      AlbumViewMode.list => Icons.view_list_rounded,
    };
    return LekisActionMenuButton<AlbumViewMode>(
      key: const ValueKey('library-album-view-mode'),
      title: l10n.pick('显示方式', 'Display Mode'),
      tooltip: l10n.pick('显示方式：${label(current)}', 'View: ${label(current)}'),
      icon: iconOf(current),
      onSelected: (mode) => ref.read(albumViewModeProvider.notifier).set(mode),
      actions: () => [
        for (final mode in AlbumViewMode.values)
          LekisMenuAction(
            mode,
            iconOf(mode),
            label(mode),
            selected: mode == current,
          ),
      ],
    );
  }
}

class _SortMenu extends ConsumerWidget {
  const _SortMenu({required this.albums});
  final bool albums;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = albums ? albumSortProvider : songSortProvider;
    final current = ref.watch(provider);
    final l10n = context.l10n;
    String label(TrackSortDto sort) => switch (sort) {
      TrackSortDto.title => l10n.pick('标题', 'Title'),
      TrackSortDto.artist => l10n.pick('艺人', 'Artist'),
      TrackSortDto.album => l10n.pick('专辑', 'Album'),
      TrackSortDto.recentlyAdded => l10n.pick('最近添加', 'Recently Added'),
      TrackSortDto.mostPlayed => l10n.pick('最常播放', 'Most Played'),
    };
    final options = albums
        ? const [
            TrackSortDto.title,
            TrackSortDto.artist,
            TrackSortDto.recentlyAdded,
          ]
        : TrackSortDto.values;
    return LekisActionMenuButton<TrackSortDto>(
      title: l10n.pick('排序', 'Sort'),
      tooltip: l10n.pick('排序：${label(current)}', 'Sort: ${label(current)}'),
      icon: Icons.sort_rounded,
      onSelected: (value) => ref.read(provider.notifier).set(value),
      actions: () => [
        for (final sort in options)
          LekisMenuAction(
            sort,
            switch (sort) {
              TrackSortDto.title => Icons.title_rounded,
              TrackSortDto.artist => Icons.person_outline_rounded,
              TrackSortDto.album => Icons.album_outlined,
              TrackSortDto.recentlyAdded => Icons.schedule_rounded,
              TrackSortDto.mostPlayed => Icons.play_circle_outline_rounded,
            },
            label(sort),
            selected: sort == current,
          ),
      ],
    );
  }
}
