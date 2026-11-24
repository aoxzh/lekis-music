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
import 'package:material_ui/material_ui.dart';

/// Which search result group is shown. The chips only appear when more than
/// one group has hits, so simple searches keep the full list.
enum _SearchFilter { all, tracks, albums, artists }

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
    ref.read(searchLimitProvider.notifier).reset();
    if (widget.pluginId == null) {
      ref.read(searchQueryProvider.notifier).set(v);
    } else {
      setState(() {});
    }
  }

  void _submit(String v) {
    _set(v);
    _remember(v);
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

    final field = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.lg,
        gutter,
        LekisSpacing.sm,
      ),
      child: SearchBar(
        controller: _text,
        focusNode: _searchFocus,
        autoFocus: _isDesktop,
        hintText: source == null
            ? l10n.pick('歌曲、专辑、艺人', 'Songs, albums, artists')
            : l10n.pick('搜索歌曲', 'Search songs'),
        leading: const Icon(Icons.search_rounded),
        trailing: [
          if (query.isNotEmpty)
            IconButton(
              tooltip: l10n.pick('清除', 'Clear'),
              onPressed: () {
                _text.clear();
                _set('');
              },
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
      body = _Hint(
        text: source == null
            ? l10n.pick('搜索你的资料库', 'Search Your Library')
            : l10n.pick('搜索在线音乐', 'Search online music'),
        message: source == null
            ? l10n.pick(
                '输入歌名、专辑、艺人，或直接输入拼音。',
                'Type a song, album, or artist name.',
              )
            : l10n.pick('输入歌名、艺人或歌曲链接。', 'Enter a song, artist, or song URL.'),
        action: fixedSource == null && _recent.isNotEmpty
            ? _RecentSearches(
                queries: _recent,
                onPick: _pickRecent,
                onRemove: _forgetRecent,
                onClear: _clearRecent,
              )
            : null,
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
          text: l10n.pick(
            '没有找到“${query.trim()}”',
            'No results for "${query.trim()}"',
          ),
          message: l10n.pick(
            '换一个关键词，或检查一下拼写。',
            'Try another keyword or check spelling.',
          ),
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
            field,
            if (fixedSource == null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const ValueKey('spotify-catalog-entry'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SpotifyCatalogPage(),
                    ),
                  ),
                  icon: const Icon(Icons.album_outlined),
                  label: Text(l10n.pick('在线专辑目录', 'Online album catalogue')),
                ),
              ),
            if (sources.isNotEmpty || source != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: gutter),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final choices = [
                      SettingsChoice('', l10n.pick('资料库', 'Library')),
                      if (source != null &&
                          !sources.any((plugin) => plugin.id == source))
                        SettingsChoice(
                          source,
                          l10n.pick('音源不可用', 'Source unavailable'),
                        ),
                      for (final plugin in sources)
                        SettingsChoice(plugin.id, plugin.name),
                    ];
                    void select(String value) => ref
                        .read(searchSourceProvider.notifier)
                        .set(value.isEmpty ? null : value);
                    final width = constraints.maxWidth.clamp(0.0, 280.0);
                    final selectedPlugin = sources
                        .where((plugin) => plugin.id == source)
                        .firstOrNull;
                    return Wrap(
                      spacing: LekisSpacing.md,
                      runSpacing: LekisSpacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (fixedSource == null)
                          Semantics(
                            label: l10n.pick('搜索音源', 'Search source'),
                            child: UiProfile.current.desktopSettings
                                ? SettingsComboBox<String>(
                                    value: source ?? '',
                                    choices: choices,
                                    minWidth: width.clamp(0.0, 128.0),
                                    maxWidth: width,
                                    onChanged: select,
                                  )
                                : SizedBox(
                                    width: width,
                                    child: DropdownButton<String>(
                                      value: source ?? '',
                                      isExpanded: true,
                                      underline: const SizedBox.shrink(),
                                      borderRadius: BorderRadius.circular(
                                        LekisRadius.md,
                                      ),
                                      items: [
                                        for (final choice in choices)
                                          DropdownMenuItem(
                                            value: choice.value,
                                            child: Text(
                                              choice.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                      onChanged: (value) {
                                        if (value != null) select(value);
                                      },
                                    ),
                                  ),
                          ),
                        if (selectedPlugin?.compatibility == 'mygo')
                          TextButton.icon(
                            icon: const Icon(Icons.folder_outlined),
                            label: Text(l10n.pick('浏览音源', 'Browse source')),
                            onPressed: () => Navigator.of(context).push(
                              PluginBrowsePage.route(
                                selectedPlugin!.id,
                                selectedPlugin.name,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
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
                PopupMenuButton<String>(
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
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'save',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.playlist_add_rounded),
                        title: Text(l10n.pick('保存为歌单', 'Save as Playlist')),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'download',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.download_for_offline_outlined,
                        ),
                        title: Text(l10n.pick('下载全部', 'Download All')),
                      ),
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
                leading: ArtistAvatar(name: a.name),
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
  const _Hint({required this.text, this.message = '', this.action});
  final String text;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) =>
      LekisEmptyState(title: text, message: message, action: action);
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.pick('最近搜索', 'Recent searches'),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextButton(
              onPressed: onClear,
              child: Text(l10n.pick('清除', 'Clear')),
            ),
          ],
        ),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: LekisSpacing.sm,
          runSpacing: LekisSpacing.xs,
          children: [
            for (final query in queries)
              InputChip(
                avatar: const Icon(Icons.history_rounded, size: 18),
                label: Text(query),
                onPressed: () => onPick(query),
                onDeleted: () => onRemove(query),
                deleteButtonTooltipMessage: l10n.pick('删除', 'Remove'),
              ),
          ],
        ),
      ],
    );
  }
}
