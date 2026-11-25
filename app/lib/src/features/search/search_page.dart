import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:lekis/src/features/plugins/plugins_providers.dart';

import '../plugins/plugin_browse_page.dart';
import '../settings/widgets/settings_widgets.dart';
import 'spotify_catalog_page.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/shelf.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart';
import 'package:lekis/src/features/search/search_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:lekis/src/widgets/action_menu.dart';
import 'package:material_ui/material_ui.dart';

/// Which search result group is shown. The chips only appear when more than
/// one group has hits, so simple searches keep the full list.
enum _SearchFilter { all, tracks, albums, artists }

const _searchPaneWidth = 880.0;

/// Search across songs, albums and artists (debounced).
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.pluginId});

  /// Fixed source for Library. Its query/results are independent of Search.
  final String? pluginId;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  static const _recentKey = 'search.recent';
  static const _maxRecent = 8;

  final _searchFocus = FocusNode(debugLabel: 'search.query');
  late final TextEditingController _text = TextEditingController(
    text: widget.pluginId == null ? ref.read(searchQueryProvider) : '',
  );
  List<String> _recent = const [];
  _SearchFilter _filter = _SearchFilter.all;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleFind);
    if (widget.pluginId == null) unawaited(_loadRecent());
  }

  bool _handleFind(KeyEvent event) {
    if (!_isDesktop || event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    if (!const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
        ).accepts(event, keyboard) &&
        !const SingleActivator(
          LogicalKeyboardKey.keyF,
          meta: true,
        ).accepts(event, keyboard)) {
      return false;
    }
    if (!TickerMode.valuesOf(context).enabled ||
        !_searchFocus.canRequestFocus ||
        ModalRoute.isCurrentOf(context) == false ||
        ModalRoute.isCurrentOf(Navigator.of(context).context) == false) {
      return false;
    }
    _searchFocus.requestFocus();
    _text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _text.text.length,
    );
    return true;
  }

  Future<void> _loadRecent() async {
    try {
      final raw = await core.getSetting(key: _recentKey);
      if (!mounted || raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final queries = decoded
          .whereType<String>()
          .map((q) => q.trim())
          .where((q) => q.isNotEmpty)
          .take(_maxRecent)
          .toList(growable: false);
      if (queries.isNotEmpty) setState(() => _recent = queries);
    } catch (_) {
      // A missing or malformed setting is the same as no history.
    }
  }

  Future<void> _saveRecent() async {
    try {
      await core.setSetting(key: _recentKey, value: jsonEncode(_recent));
    } catch (_) {
      // Search still works if history cannot be persisted.
    }
  }

  void _remember(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    final next = [
      query,
      ..._recent.where((q) => q.toLowerCase() != query.toLowerCase()),
    ].take(_maxRecent).toList(growable: false);
    setState(() => _recent = next);
    unawaited(_saveRecent());
  }

  void _clearRecent() {
    setState(() => _recent = const []);
    unawaited(_saveRecent());
  }

  void _forgetRecent(String query) {
    final next = [
      for (final q in _recent)
        if (q != query) q,
    ];
    setState(() => _recent = next);
    unawaited(_saveRecent());
  }

  void _pickRecent(String query) {
    _text.text = query;
    _text.selection = TextSelection.collapsed(offset: query.length);
    _set(query);
    _remember(query);
  }

  @override
  void didUpdateWidget(covariant SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pluginId != widget.pluginId) {
      _text.text = widget.pluginId == null ? ref.read(searchQueryProvider) : '';
      _filter = _SearchFilter.all;
      if (widget.pluginId == null) unawaited(_loadRecent());
    }
  }

  bool get _isDesktop => UiProfile.current.pointerFirst;

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleFind);
    _searchFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _set(String v) {
    _filter = _SearchFilter.all;
    if (widget.pluginId == null) {
      ref.read(searchLimitProvider.notifier).reset();
      ref.read(searchQueryProvider.notifier).set(v);
    } else {
      setState(() {});
    }
  }

  void _submit(String v) {
    _set(v);
    if (widget.pluginId == null) _remember(v);
  }

  void _clearQuery() {
    _text.clear();
    _set('');
    _searchFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final gutter = pageGutterOf(context);
    final fixedSource = widget.pluginId;
    final query = fixedSource == null
        ? ref.watch(searchQueryProvider)
        : _text.text;
    final results = fixedSource == null
        ? ref.watch(searchResultsProvider)
        : ref.watch(librarySourceSearchProvider((fixedSource, query)));
    final source = fixedSource ?? ref.watch(searchSourceProvider);
    final sources = (ref.watch(pluginListProvider).value ?? <PluginInfoDto>[])
        .where(
          (plugin) =>
              plugin.enabled &&
              plugin.error == null &&
              plugin.kinds.contains('source'),
        )
        .toList();

    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final field = Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _text.text.isNotEmpty &&
            _text.value.composing.isCollapsed) {
          _clearQuery();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SearchBar(
        controller: _text,
        focusNode: _searchFocus,
        autoFocus: _isDesktop,
        constraints: const BoxConstraints(minHeight: 48),
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(colors.surfaceElevated),
        padding: const WidgetStatePropertyAll(
          EdgeInsetsDirectional.only(start: 14, end: 4),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LekisRadius.md),
          ),
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.focused)
                ? theme.colorScheme.primary
                : colors.outline,
          ),
        ),
        textStyle: WidgetStatePropertyAll(theme.textTheme.bodyLarge),
        hintStyle: WidgetStatePropertyAll(
          theme.textTheme.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
        ),
        hintText: source == null
            ? l10n.pick('歌曲、专辑、艺人', 'Songs, albums, artists')
            : l10n.pick('搜索歌曲', 'Search songs'),
        leading: Icon(
          Icons.search_rounded,
          size: 21,
          color: colors.onSurfaceVariant,
        ),
        trailing: [
          if (query.isNotEmpty)
            IconButton(
              tooltip: l10n.pick('清除', 'Clear'),
              onPressed: _clearQuery,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
        onChanged: _set,
        onSubmitted: _submit,
        textInputAction: TextInputAction.search,
      ),
    );

    Widget body;
    var loading = false;
    if (query.trim().isEmpty) {
      body = fixedSource == null && _recent.isNotEmpty
          ? _RecentSearches(
              queries: _recent,
              onPick: _pickRecent,
              onRemove: _forgetRecent,
              onClear: _clearRecent,
            )
          : _Hint(
              icon: source == null
                  ? Icons.library_music_outlined
                  : Icons.travel_explore_rounded,
              text: source == null
                  ? l10n.pick('搜索你的资料库', 'Search Your Library')
                  : l10n.pick('搜索在线音乐', 'Search online music'),
              message: source == null
                  ? l10n.pick(
                      '中文名称也支持拼音搜索。',
                      'You can also search Chinese names using pinyin.',
                    )
                  : l10n.pick(
                      '输入歌名、艺人或歌曲链接。',
                      'Enter a song, artist, or song URL.',
                    ),
            );
    } else {
      final data = results.value;
      // Riverpod retains previous data while refreshing and after a failure.
      // Only a completed, successful request may expose playable results.
      if (results.hasError && !results.isLoading) {
        body = LoadErrorView(
          error: results.error!,
          onRetry: () {
            if (fixedSource == null) {
              ref.invalidate(searchResultsProvider);
            } else {
              ref.invalidate(librarySourceSearchProvider((fixedSource, query)));
            }
          },
        );
      } else if (results.isLoading || data == null) {
        loading = true;
        body = const SizedBox.shrink();
      } else if (data.tracks.isEmpty &&
          data.albums.isEmpty &&
          data.artists.isEmpty) {
        body = _Hint(
          icon: Icons.search_off_rounded,
          text: l10n.pick(
            '没有找到“${query.trim()}”',
            'No results for "${query.trim()}"',
          ),
          message: l10n.pick(
            '换一个关键词，或检查一下拼写。',
            'Try another keyword or check spelling.',
          ),
          actions: [
            if (source == null)
              for (final plugin in sources)
                TextButton.icon(
                  icon: const Icon(Icons.travel_explore_rounded, size: 18),
                  label: Text(
                    l10n.pick(
                      '在 ${plugin.name} 搜索“${query.trim()}”',
                      'Search ${plugin.name} for “${query.trim()}”',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () {
                    ref.read(searchLimitProvider.notifier).reset();
                    ref.read(searchSourceProvider.notifier).set(plugin.id);
                  },
                ),
          ],
        );
      } else {
        body = _Results(
          results: data,
          pluginId: source,
          filter: _filter,
          onFilter: (value) => setState(() => _filter = value),
        );
      }
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _searchPaneWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      field,
                      const SizedBox(height: 4),
                      _SearchTools(
                        source: source,
                        fixed: fixedSource != null,
                        sources: sources,
                        onSelect: (value) => ref
                            .read(searchSourceProvider.notifier)
                            .set(value.isEmpty ? null : value),
                      ),
                      const Divider(height: 1),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: LekisLoadingSwitcher(
                // Do not retain the previous request's interactive content
                // during the switcher's delayed skeleton or outgoing fade.
                key: ValueKey((query.trim(), source, loading)),
                loading: loading,
                skeleton: SkeletonTrackListView(
                  header: Padding(
                    padding: EdgeInsets.fromLTRB(
                      gutter,
                      LekisSpacing.xl,
                      gutter,
                      LekisSpacing.sm,
                    ),
                    child: const SizedBox(
                      height: LekisSpacing.xl + LekisSpacing.xs,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: LekisSkeleton.line(
                          width: LekisSpacing.xxxl,
                          height: LekisSpacing.lg + LekisSpacing.xxs,
                        ),
                      ),
                    ),
                  ),
                ),
                child: body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchTools extends StatelessWidget {
  const _SearchTools({
    required this.source,
    required this.fixed,
    required this.sources,
    required this.onSelect,
  });
  final String? source;
  final bool fixed;
  final List<PluginInfoDto> sources;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final selected = sources.where((plugin) => plugin.id == source).firstOrNull;
    final choices = [
      SettingsChoice('', l10n.pick('资料库', 'Library')),
      if (source != null && selected == null)
        SettingsChoice(source!, l10n.pick('音源不可用', 'Source unavailable')),
      for (final plugin in sources) SettingsChoice(plugin.id, plugin.name),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final maxWidth = bounds.maxWidth.clamp(0.0, 208.0);
          final scope = l10n.pick('搜索范围', 'Search in');
          final selectable = !fixed && choices.length > 1;
          return Wrap(
            spacing: 16,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(
                    scope,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: context.lekisColors.onSurfaceVariant,
                    ),
                  ),
                  if (selectable)
                    Semantics(
                      label: scope,
                      child: UiProfile.current.desktopSettings
                          ? SettingsComboBox<String>(
                              value: source ?? '',
                              choices: choices,
                              minWidth: maxWidth.clamp(0, 100),
                              maxWidth: maxWidth,
                              onChanged: onSelect,
                            )
                          : SizedBox(
                              width: maxWidth.clamp(
                                0,
                                source == null ? 104 : 154,
                              ),
                              child: LekisActionMenuButton<String>(
                                key: const ValueKey('search-source-picker'),
                                title: scope,
                                tooltip: scope,
                                onSelected: onSelect,
                                actions: () => [
                                  for (final choice in choices)
                                    LekisMenuAction(
                                      choice.value,
                                      choice.value.isEmpty
                                          ? Icons.library_music_outlined
                                          : Icons.extension_outlined,
                                      choice.label,
                                      selected: choice.value == (source ?? ''),
                                    ),
                                ],
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight: LekisSizes.touchTargetMin,
                                  ),
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          choices
                                              .firstWhere(
                                                (choice) =>
                                                    choice.value ==
                                                    (source ?? ''),
                                              )
                                              .label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodyMedium,
                                        ),
                                      ),
                                      const Icon(Icons.arrow_drop_down_rounded),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                    )
                  else
                    Text(
                      source == null
                          ? choices.first.label
                          : selected?.name ??
                                l10n.pick('音源不可用', 'Source unavailable'),
                      style: theme.textTheme.titleSmall,
                    ),
                ],
              ),
              if (!fixed)
                TextButton.icon(
                  key: const ValueKey('spotify-catalog-entry'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SpotifyCatalogPage(),
                    ),
                  ),
                  icon: const Icon(Icons.album_outlined, size: 18),
                  label: Text(
                    l10n.pick('在线专辑目录', 'Online album catalogue'),
                    style: theme.textTheme.labelLarge,
                  ),
                ),
              if (selected != null && selected.compatibility == 'mygo')
                TextButton.icon(
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  label: Text(
                    l10n.pick('浏览音源', 'Browse source'),
                    style: theme.textTheme.labelLarge,
                  ),
                  onPressed: () => Navigator.of(context)
                      .push(PluginBrowsePage.route(selected.id, selected.name)),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({
    required this.results,
    required this.filter,
    required this.onFilter,
    this.pluginId,
  });

  final SearchResultsDto results;
  final _SearchFilter filter;
  final ValueChanged<_SearchFilter> onFilter;
  final String? pluginId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gutter = pageGutterOf(context);
    final theme = Theme.of(context);
    final tracks = results.tracks;
    final albums = results.albums;
    final artists = results.artists;
    final l10n = context.l10n;
    final limit = ref.watch(searchLimitProvider);
    final canMore =
        pluginId == null &&
        (tracks.length >= limit ||
            albums.length >= limit ||
            artists.length >= limit);
    final showFilters =
        [
          tracks.isNotEmpty,
          albums.isNotEmpty,
          artists.isNotEmpty,
        ].where((nonEmpty) => nonEmpty).length >
        1;
    final showTracks =
        filter == _SearchFilter.all || filter == _SearchFilter.tracks;
    final showAlbums =
        filter == _SearchFilter.all || filter == _SearchFilter.albums;
    final showArtists =
        filter == _SearchFilter.all || filter == _SearchFilter.artists;

    Widget sectionTitle(String t, {List<Widget> actions = const []}) => Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.xl,
        gutter,
        LekisSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(t, style: theme.textTheme.titleLarge),
            ),
          ),
          ...actions,
        ],
      ),
    );

    return CustomScrollView(
      slivers: [
        if (showFilters)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                gutter,
                LekisSpacing.sm,
                gutter,
                LekisSpacing.xs,
              ),
              child: Wrap(
                spacing: LekisSpacing.sm,
                runSpacing: LekisSpacing.xs,
                children: [
                  ChoiceChip(
                    label: Text(l10n.pick('全部', 'All')),
                    selected: filter == _SearchFilter.all,
                    onSelected: (_) => onFilter(_SearchFilter.all),
                  ),
                  if (tracks.isNotEmpty)
                    ChoiceChip(
                      label: Text('${l10n.segSongs} ${tracks.length}'),
                      selected: filter == _SearchFilter.tracks,
                      onSelected: (_) => onFilter(_SearchFilter.tracks),
                    ),
                  if (albums.isNotEmpty)
                    ChoiceChip(
                      label: Text('${l10n.segAlbums} ${albums.length}'),
                      selected: filter == _SearchFilter.albums,
                      onSelected: (_) => onFilter(_SearchFilter.albums),
                    ),
                  if (artists.isNotEmpty)
                    ChoiceChip(
                      label: Text('${l10n.segArtists} ${artists.length}'),
                      selected: filter == _SearchFilter.artists,
                      onSelected: (_) => onFilter(_SearchFilter.artists),
                    ),
                ],
              ),
            ),
          ),
        if (showTracks && tracks.isNotEmpty)
          SliverToBoxAdapter(
            child: sectionTitle(
              l10n.segSongs,
              actions: [
                IconButton(
                  tooltip: l10n.pick('播放全部', 'Play all'),
                  onPressed: () =>
                      ref.read(playerActionsProvider).playRows(tracks),
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
                IconButton(
                  tooltip: l10n.pick('随机播放', 'Shuffle all'),
                  onPressed: () => ref
                      .read(playerActionsProvider)
                      .playRows(tracks, shuffle: true),
                  icon: const Icon(Icons.shuffle_rounded),
                ),
                LekisActionMenuButton<String>(
                  title: context.l10n.pick('搜索结果', 'Search Results'),
                  tooltip: l10n.pick('更多操作', 'More Actions'),
                  onSelected: (value) {
                    switch (value) {
                      case 'save':
                        final stamp = DateTime.now()
                            .toString()
                            .substring(0, 16)
                            .replaceAll('T', ' ');
                        unawaited(
                          saveTracksAsPlaylistFlow(
                            context,
                            ref,
                            tracks,
                            suggestedName:
                                '${l10n.pick('搜索结果', 'Search Results')} $stamp',
                          ),
                        );
                      case 'download':
                        final ids = [
                          for (final track in tracks)
                            if (!track.isLocal) track.id,
                        ];
                        if (ids.isEmpty) {
                          ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(
                              SnackBar(
                                content: Text(
                                  l10n.pick(
                                    '没有可下载的曲目',
                                    'No tracks available to download',
                                  ),
                                ),
                              ),
                            );
                          return;
                        }
                        unawaited(startDownloads(context, ref, ids));
                    }
                  },
                  actions: () => [
                    LekisMenuAction(
                      'save',
                      Icons.playlist_add_rounded,
                      context.l10n.pick('保存为歌单', 'Save as Playlist'),
                    ),
                    LekisMenuAction(
                      'download',
                      Icons.download_for_offline_outlined,
                      context.l10n.pick('下载全部', 'Download All'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
          sliver: SliverFixedExtentList.builder(
            itemExtent: TrackTile.extent,
            itemCount: showTracks ? tracks.length : 0,
            itemBuilder: (context, i) => TrackTile(
              track: tracks[i],
              onlinePlugin: pluginId != null,
              pluginId: pluginId,
              onTap: () =>
                  ref.read(playerActionsProvider).playRows(tracks, start: i),
            ),
          ),
        ),
        if (showAlbums && albums.isNotEmpty)
          SliverToBoxAdapter(
            child: ArtworkShelf(
              title: l10n.segAlbums,
              itemCount: albums.length,
              itemBuilder: (context, i) => AlbumCard(
                album: albums[i],
                onTap: () =>
                    Navigator.of(context)
                        .push(AlbumDetailPage.route(albums[i].id)),
              ),
            ),
          ),
        if (showArtists && artists.isNotEmpty)
          SliverToBoxAdapter(child: sectionTitle(l10n.segArtists)),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
          sliver: SliverList.builder(
            itemCount: showArtists ? artists.length : 0,
            itemBuilder: (context, i) {
              final a = artists[i];
              return ListTile(
                minTileHeight: LekisSizes.touchTargetMin + LekisSpacing.md,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(LekisRadius.sm),
                ),
                leading: ArtistAvatar(name: a.name, artistId: a.id),
                title: Text(a.name),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () =>
                    Navigator.of(context).push(ArtistDetailPage.route(a.id)),
              );
            },
          ),
        ),
        if (canMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(gutter, LekisSpacing.lg, gutter, 0),
              child: Center(
                child: TextButton.icon(
                  onPressed: limit >= searchMaxLimit
                      ? null
                      : () => ref.read(searchLimitProvider.notifier).more(),
                  icon: const Icon(Icons.expand_more_rounded),
                  label: Text(
                    limit >= searchMaxLimit
                        ? l10n.pick(
                            '已显示前 $searchMaxLimit 个结果',
                            'Showing first $searchMaxLimit results',
                          )
                        : l10n.pick('显示更多结果', 'Show more results'),
                  ),
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.only(bottom: scrollEndPadding(context)),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.text,
    required this.message,
    this.actions = const [],
  });
  final IconData icon;
  final String text;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: pageGutterOf(context),
        vertical: 28,
      ),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: context.lekisColors.surfaceVariant,
                borderRadius: BorderRadius.circular(LekisRadius.md),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  icon,
                  size: 24,
                  color: context.lekisColors.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(text, style: theme.textTheme.titleLarge),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: context.lekisColors.onSurfaceVariant,
                    ),
                  ),
                  if (actions.isNotEmpty)
                    Wrap(spacing: LekisSpacing.sm, children: actions),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RecentSearches extends StatelessWidget {
  const _RecentSearches({
    required this.queries,
    required this.onPick,
    required this.onRemove,
    required this.onClear,
  });

  final List<String> queries;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        pageGutterOf(context),
        16,
        pageGutterOf(context),
        scrollEndPadding(context),
      ),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _searchPaneWidth),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          l10n.pick('最近搜索', 'Recent searches'),
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: onClear,
                      child: Text(
                        l10n.pick('清空', 'Clear all'),
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
                for (final query in queries)
                  ListTile(
                    key: ValueKey(query),
                    contentPadding: const EdgeInsetsDirectional.only(start: 8),
                    minTileHeight: 48,
                    leading: Icon(
                      Icons.history_rounded,
                      size: 18,
                      color: context.lekisColors.onSurfaceVariant,
                    ),
                    title: Text(
                      query,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    onTap: () => onPick(query),
                    trailing: IconButton(
                      tooltip: l10n.pick('移除“$query”', 'Remove "$query"'),
                      onPressed: () => onRemove(query),
                      icon: const Icon(Icons.close_rounded, size: 16),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
