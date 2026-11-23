import 'dart:async';
import 'dart:convert';

import 'package:lekis/src/features/plugins/plugins_providers.dart';

import '../plugins/plugin_browse_page.dart';
import '../settings/widgets/settings_widgets.dart';
import 'spotify_catalog_page.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/shelf.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/search/search_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:material_ui/material_ui.dart';

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

  late final TextEditingController _text = TextEditingController(
    text: widget.pluginId == null ? ref.read(searchQueryProvider) : '',
  );
  List<String> _recent = const [];

  @override
  void initState() {
    super.initState();
    if (widget.pluginId == null) unawaited(_loadRecent());
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
    _text.dispose();
    super.dispose();
  }

  void _set(String v) {
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
        body = _Results(results: data, onlinePlugin: source != null);
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
  const _Results({required this.results, this.onlinePlugin = false});

  final SearchResultsDto results;
  final bool onlinePlugin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gutter = pageGutterOf(context);
    final theme = Theme.of(context);
    final tracks = results.tracks;
    Widget sectionTitle(String t) => Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.xl,
        gutter,
        LekisSpacing.sm,
      ),
      child: Semantics(
        header: true,
        child: Text(t, style: theme.textTheme.titleLarge),
      ),
    );

    final l10n = context.l10n;
    return CustomScrollView(
      slivers: [
        if (tracks.isNotEmpty)
          SliverToBoxAdapter(child: sectionTitle(l10n.segSongs)),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
          sliver: SliverFixedExtentList.builder(
            itemExtent: TrackTile.extent,
            itemCount: tracks.length,
            itemBuilder: (context, i) => TrackTile(
              track: tracks[i],
              onlinePlugin: onlinePlugin,
              onTap: () =>
                  ref.read(playerActionsProvider).playRows(tracks, start: i),
            ),
          ),
        ),
        if (results.albums.isNotEmpty)
          SliverToBoxAdapter(
            child: ArtworkShelf(
              title: l10n.segAlbums,
              itemCount: results.albums.length,
              itemBuilder: (context, i) => AlbumCard(
                album: results.albums[i],
                onTap: () =>
                    Navigator.of(context)
                        .push(AlbumDetailPage.route(results.albums[i].id)),
              ),
            ),
          ),
        if (results.artists.isNotEmpty)
          SliverToBoxAdapter(child: sectionTitle(l10n.segArtists)),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
          sliver: SliverList.builder(
            itemCount: results.artists.length,
            itemBuilder: (context, i) {
              final a = results.artists[i];
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
    required this.onClear,
  });

  final List<String> queries;
  final ValueChanged<String> onPick;
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
              ActionChip(
                avatar: const Icon(Icons.history_rounded, size: 18),
                label: Text(query),
                onPressed: () => onPick(query),
              ),
          ],
        ),
      ],
    );
  }
}
