// 歌单详情：普通歌单可增删 / 上下移动；智能歌单展示实时规则结果。

import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:lekis/src/widgets/progress_dialog.dart';

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/library/artwork_actions.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart';
import 'package:lekis/src/features/playlists/playlist_cover.dart';
import 'package:lekis/src/features/playlists/playlist_m3u.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/features/playlists/smart_playlist_editor_page.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/nav_icon.dart' show lekisReduceMotion;
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/list_motion.dart';
import 'package:lekis/src/widgets/mascot.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_actions.dart';
import 'package:lekis/src/widgets/action_menu.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lekis/src/features/playlists/playlist_strings.dart';

class PlaylistDetailPage extends StatelessWidget {
  const PlaylistDetailPage({super.key, required this.playlistId, this.scope});

  final int playlistId;
  final LibraryScope? scope;

  static Route<void> route(int playlistId, {LibraryScope? scope}) =>
      MaterialPageRoute<void>(
        settings: RouteSettings(name: '/playlist/$playlistId'),
        builder: (_) =>
            PlaylistDetailPage(playlistId: playlistId, scope: scope),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: PlaylistDetailView(playlistId: playlistId, scope: scope),
  );
}

class PlaylistDetailView extends ConsumerStatefulWidget {
  const PlaylistDetailView({super.key, required this.playlistId, this.scope});

  final int playlistId;
  final LibraryScope? scope;

  @override
  ConsumerState<PlaylistDetailView> createState() => _PlaylistDetailViewState();
}

class _PlaylistDetailViewState extends ConsumerState<PlaylistDetailView> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showPlaylistError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _refresh() {
    ref.invalidate(playlistProvider(widget.playlistId));
    ref.invalidate(playlistEntriesProvider(widget.playlistId));
    ref.invalidate(smartPlaylistTracksProvider(widget.playlistId));
    ref.invalidate(playlistRulesProvider(widget.playlistId));
    ref.invalidate(playlistsProvider);
  }

  Future<void> _move(
    PlaylistDto playlist,
    List<PlaylistEntryDto> entries,
    int index, {
    required bool up,
  }) async {
    if (up && index == 0) return;
    if (!up && index >= entries.length - 1) return;
    final entry = entries[index];
    final before = up
        ? (index >= 2 ? entries[index - 2].positionKey : null)
        : entries[index + 1].positionKey;
    final after = up
        ? entries[index - 1].positionKey
        : (index + 2 < entries.length ? entries[index + 2].positionKey : null);
    await _run(() async {
      await core.movePlaylistItem(
        playlistId: playlist.id,
        positionKey: entry.positionKey,
        beforeKey: before,
        afterKey: after,
      );
      _refresh();
    });
  }

  Future<void> _remove(PlaylistDto playlist, PlaylistEntryDto entry) async {
    await _run(() async {
      await core.removeFromPlaylist(
        playlistId: playlist.id,
        positionKey: entry.positionKey,
        expectedTrackUid: entry.trackUid,
      );
      _refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(playlistProvider(widget.playlistId));
    if (loaded.hasError) {
      return Center(
        child: Text(
          PlaylistStrings.playlistLoadFailed(describeCoreError(loaded.error!)),
        ),
      );
    }
    final playlist = loaded.value;
    if (playlist == null) {
      return const LekisDelayedSkeleton(
        child: SkeletonTrackListView(top: LekisSpacing.lg),
      );
    }
    final scope = widget.scope;
    if (scope != null) {
      final provider = scopedPlaylistTracksProvider((
        scope: scope,
        playlistId: playlist.id,
      ));
      final active = ref.watch(librarySourceProvider);
      final tracks = active == scope
          ? ref.watch(provider)
          : const AsyncData(<TrackRowDto>[]);
      return tracks.when(
        error: (error, _) => Center(
          child: Text(
            PlaylistStrings.entriesLoadFailed(describeCoreError(error)),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        data: (rows) {
          final actions = ref.read(playerActionsProvider);
          final gutter = pageGutterOf(context);
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(
              gutter,
              LekisSpacing.md,
              gutter,
              scrollEndPadding(context),
            ),
            itemCount: rows.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _PlaylistHeader(
                      playlist: playlist,
                      subtitle: PlaylistStrings.detailSubtitle(rows.length),
                      queueTrackIds: [for (final row in rows) row.id],
                      onPlay: rows.isEmpty
                          ? null
                          : () => actions.playRows(rows),
                      onShuffle: rows.isEmpty
                          ? null
                          : () => actions.playRows(rows, shuffle: true),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.edit_outlined),
                      label: Text(
                        context.l10n.pick('编辑完整歌单', 'Edit full playlist'),
                      ),
                      onPressed: () =>
                          Navigator.of(context)
                              .push(PlaylistDetailPage.route(playlist.id)),
                    ),
                  ],
                );
              }
              return TrackTile(
                track: rows[index - 1],
                onlinePlugin: scope.kind == LibraryScopeKind.plugin,
                pluginId: scope.pluginId,
                onTap: () => actions.playRows(rows, start: index - 1),
              );
            },
          );
        },
      );
    }
    return playlist.kind == PlaylistKindDto.smart
        ? _SmartPlaylistBody(playlist: playlist)
        : _StaticPlaylistBody(
            playlist: playlist,
            busy: _busy,
            onMove: (entries, index, up) =>
                _move(playlist, entries, index, up: up),
            onRemove: (entry) => _remove(playlist, entry),
          );
  }
}

class _StaticPlaylistBody extends ConsumerStatefulWidget {
  const _StaticPlaylistBody({
    required this.playlist,
    required this.busy,
    required this.onMove,
    required this.onRemove,
  });

  final PlaylistDto playlist;
  final bool busy;
  final Future<void> Function(
    List<PlaylistEntryDto> entries,
    int index,
    bool up,
  )
  onMove;
  final Future<void> Function(PlaylistEntryDto entry) onRemove;

  @override
  ConsumerState<_StaticPlaylistBody> createState() =>
      _StaticPlaylistBodyState();
}

class _StaticPlaylistBodyState extends ConsumerState<_StaticPlaylistBody> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _selecting = false;
  final Map<String, String> _selectedKeys = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(playlistEntriesProvider(widget.playlist.id));
    ref.invalidate(playlistsProvider);
  }

  void _toggleSelected(PlaylistEntryDto entry) {
    setState(() {
      if (_selectedKeys[entry.positionKey] == entry.trackUid) {
        _selectedKeys.remove(entry.positionKey);
      } else {
        _selectedKeys[entry.positionKey] = entry.trackUid;
      }
      _selecting = _selectedKeys.isNotEmpty;
    });
  }

  void _clearSelection() {
    if (!_selecting && _selectedKeys.isEmpty) return;
    setState(() {
      _selecting = false;
      _selectedKeys.clear();
    });
  }

  Future<void> _removeSelected(
    PlaylistDto playlist,
    List<PlaylistEntryDto> rows,
    Set<String> selectedKeys,
  ) async {
    final entries = [
      for (final entry in rows)
        if (selectedKeys.contains(entry.positionKey)) entry,
    ];
    if (entries.isEmpty) {
      // Position keys can change under the selection (sort, merge, a move from
      // another surface); never leave the bar pointing at rows that are gone.
      if (mounted) {
        setState(() {
          _selecting = false;
          _selectedKeys.clear();
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(PlaylistStrings.selectionExpired)),
          );
      }
      return;
    }
    final confirmed = await showLekisPanel<bool>(
      context,
      builder: (dialog) => LekisPanel(
        title: PlaylistStrings.removeSelectedTitle(entries.length),
        body: Text(PlaylistStrings.removeSelectedBody(entries.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(PlaylistStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(PlaylistStrings.removeSelected),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final progress = ValueNotifier<int>(0);
    final closeProgress = showProgressPanel(
      context,
      title: PlaylistStrings.removingSelected,
      progress: progress,
      builder: (done) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: entries.isEmpty
                ? 0
                : (done / entries.length).clamp(0.0, 1.0),
          ),
          const SizedBox(height: LekisSpacing.md),
          Text('$done / ${entries.length}'),
        ],
      ),
    );

    var removed = 0;
    var failed = 0;
    try {
      for (final entry in entries) {
        try {
          await core.removeFromPlaylist(
            playlistId: playlist.id,
            positionKey: entry.positionKey,
            expectedTrackUid: entry.trackUid,
          );
          removed++;
        } catch (_) {
          failed++;
        }
        progress.value++;
      }
      if (mounted) _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(PlaylistStrings.removedSelected(removed, failed)),
            ),
          );
      }
    } catch (e) {
      if (mounted) showPlaylistError(context, e);
    } finally {
      await closeProgress();
      if (mounted) {
        setState(() {
          _selecting = false;
          _selectedKeys.clear();
        });
      }
    }
  }

  Future<void> _moveToTop(PlaylistEntryDto entry) async {
    if (widget.busy) return;
    try {
      final first = await core.playlistItems(
        playlistId: widget.playlist.id,
        offset: 0,
        limit: 1,
      );
      if (first.isEmpty) return;
      await core.movePlaylistItem(
        playlistId: widget.playlist.id,
        positionKey: entry.positionKey,
        afterKey: first.first.positionKey,
      );
      if (!mounted) return;
      ref.invalidate(playlistEntriesProvider(widget.playlist.id));
      ref.invalidate(playlistsProvider);
    } catch (e) {
      if (mounted) showPlaylistError(context, e);
    }
  }

  Future<void> _moveToBottom(PlaylistEntryDto entry) async {
    if (widget.busy) return;
    try {
      await core.movePlaylistItem(
        playlistId: widget.playlist.id,
        positionKey: entry.positionKey,
      );
      if (!mounted) return;
      ref.invalidate(playlistEntriesProvider(widget.playlist.id));
      ref.invalidate(playlistsProvider);
    } catch (e) {
      if (mounted) showPlaylistError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
    final entries = ref.watch(playlistEntriesProvider(playlist.id));
    final playlists =
        ref.watch(playlistsProvider).value ?? const <PlaylistDto>[];
    final gutter = pageGutterOf(context);
    final rows = entries.value ?? const <PlaylistEntryDto>[];
    final totalDuration = ref.watch(playlistTotalDurationProvider(playlist.id));
    final playableIds = rows
        .where((entry) => entry.track != null)
        .map((entry) => entry.track!.id)
        .toList(growable: false);
    final downloadIds = rows
        .where((entry) => entry.track != null && !entry.track!.isLocal)
        .map((entry) => entry.track!.id)
        .toList(growable: false);
    final query = _query.trim().toLowerCase();
    final visible = query.isEmpty
        ? rows
        : [
            for (final entry in rows)
              if (entry.track != null &&
                  (entry.track!.title.toLowerCase().contains(query) ||
                      entry.track!.artistLine.toLowerCase().contains(query) ||
                      (entry.track!.albumTitle?.toLowerCase().contains(query) ??
                          false)))
                entry,
          ];
    // Position keys are rewritten whenever a row moves, so a selection made
    // before a sort/merge/move may point at keys that no longer exist. Only
    // show and act on keys that are still in the current list.
    final selectedKeys = {
      for (final entry in rows)
        if (_selectedKeys[entry.positionKey] == entry.trackUid)
          entry.positionKey,
    };

    final content = CustomScrollView(
      key: PageStorageKey('playlist-${playlist.id}'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            LekisSpacing.md,
            gutter,
            LekisSpacing.lg,
          ),
          sliver: SliverToBoxAdapter(
            child: _PlaylistHeader(
              playlist: playlist,
              subtitle: PlaylistStrings.detailSubtitle(
                rows.isEmpty ? playlist.trackCount : rows.length,
                total: totalDuration,
              ),
              onPlay: rows.any((e) => e.track != null)
                  ? () => playPlaylistContext(context, playlist)
                  : null,
              onShuffle: rows.any((e) => e.track != null)
                  ? () => playPlaylistContext(context, playlist, shuffle: true)
                  : null,
              onDownload: downloadIds.isEmpty
                  ? null
                  : () => startDownloads(context, ref, downloadIds),
              onExport: () => exportPlaylistM3uFlow(context, playlist),
              onSort: rows.length < 2
                  ? null
                  : () => showPlaylistSortSheet(context, ref, playlist, rows),
              onCopy: rows.isEmpty
                  ? null
                  : () => copyPlaylistAsText(context, rows),
              onDedupe: rows.length < 2
                  ? null
                  : () => removePlaylistDuplicatesFlow(
                      context,
                      ref,
                      playlist,
                      rows,
                    ),
              onCleanMissing: rows.any((e) => e.track == null)
                  ? () => removeMissingPlaylistEntriesFlow(
                      context,
                      ref,
                      playlist,
                      rows,
                    )
                  : null,
              onMerge: playlist.kind == PlaylistKindDto.static_
                  ? () => mergePlaylistFlow(context, ref, playlist, playlists)
                  : null,
              onSelect: rows.isEmpty
                  ? null
                  : () {
                      setState(() {
                        _selecting = true;
                        _selectedKeys.clear();
                      });
                    },
              queueTrackIds: playableIds,
            ),
          ),
        ),
        if (rows.length >= 8)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, LekisSpacing.sm),
              child: TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: PlaylistStrings.searchPlaylist,
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: PlaylistStrings.clearSearch,
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                  isDense: true,
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(LekisRadius.pill),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
        if (entries.hasError)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(gutter),
              child: Text(
                PlaylistStrings.entriesLoadFailed(
                  describeCoreError(entries.error!),
                ),
              ),
            ),
          )
        else if (entries.isLoading && rows.isEmpty)
          SliverToBoxAdapter(
            child: LekisDelayedSkeleton(
              child: SkeletonTrackList(
                padding: EdgeInsets.symmetric(
                  horizontal: gutter - LekisSpacing.sm,
                ),
              ),
            ),
          )
        else if (rows.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyPlaylistBody(isSmart: false),
          )
        else if (visible.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                PlaylistStrings.noMatchingTracks,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
            sliver: _PlaylistEntryList(
              playlist: playlist,
              rows: visible,
              busy: widget.busy || query.isNotEmpty || _selecting,
              selecting: _selecting,
              selectedKeys: selectedKeys,
              onToggleSelect: _toggleSelected,
              onMove: widget.onMove,
              onRemove: widget.onRemove,
              onMoveToTop: _moveToTop,
              onMoveToBottom: _moveToBottom,
              onPlayIndex: query.isEmpty
                  ? null
                  : (i) => ref.read(playerActionsProvider).playRows([
                      for (final entry in visible) entry.track!,
                    ], start: i),
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.only(
            bottom:
                scrollEndPadding(context) +
                (_selecting ? LekisSizes.touchTargetMin + LekisSpacing.xl : 0),
          ),
        ),
      ],
    );

    if (!_selecting) return content;
    final allVisibleSelected =
        visible.isNotEmpty &&
        visible.every((entry) => selectedKeys.contains(entry.positionKey));
    return Stack(
      children: [
        Positioned.fill(child: content),
        Positioned(
          left: gutter,
          right: gutter,
          bottom: LekisSpacing.lg,
          child: SafeArea(
            top: false,
            child: _SelectionBar(
              count: selectedKeys.length,
              visibleCount: visible.length,
              allVisibleSelected: allVisibleSelected,
              onToggleVisible: visible.isEmpty
                  ? null
                  : () => setState(() {
                      for (final entry in visible) {
                        if (allVisibleSelected) {
                          _selectedKeys.remove(entry.positionKey);
                        } else {
                          _selectedKeys[entry.positionKey] = entry.trackUid;
                        }
                      }
                    }),
              onCancel: _clearSelection,
              onRemove: selectedKeys.isEmpty
                  ? null
                  : () => _removeSelected(playlist, rows, selectedKeys),
            ),
          ),
        ),
      ],
    );
  }
}

class _SmartPlaylistBody extends ConsumerWidget {
  const _SmartPlaylistBody({required this.playlist});

  final PlaylistDto playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(smartPlaylistTracksProvider(playlist.id));
    final rules = ref.watch(playlistRulesProvider(playlist.id));
    final gutter = pageGutterOf(context);
    final rows = tracks.value ?? const <TrackRowDto>[];

    return CustomScrollView(
      key: PageStorageKey('smart-playlist-${playlist.id}'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            LekisSpacing.md,
            gutter,
            LekisSpacing.lg,
          ),
          sliver: SliverToBoxAdapter(
            child: _PlaylistHeader(
              playlist: playlist,
              subtitle: rules.value == null
                  ? PlaylistStrings.smartSubtitle
                  : PlaylistStrings.smartMatched(
                      rows.length,
                      rows.length >= 5000,
                    ),
              onPlay: rows.isEmpty
                  ? null
                  : () => playPlaylistContext(context, playlist),
              onEditRules: () => Navigator.of(context).push(
                SmartPlaylistEditorPage.route(playlist.id, name: playlist.name),
              ),
              onCopy: rows.isEmpty
                  ? null
                  : () => copyPlaylistTracksAsText(context, rows),
              queueTrackIds: [for (final r in rows) r.id],
            ),
          ),
        ),
        if (tracks.hasError)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(gutter),
              child: Text(
                PlaylistStrings.rulesEvalFailed(
                  describeCoreError(tracks.error!),
                ),
              ),
            ),
          )
        else if (tracks.isLoading && rows.isEmpty)
          SliverToBoxAdapter(
            child: LekisDelayedSkeleton(
              child: SkeletonTrackList(
                padding: EdgeInsets.symmetric(
                  horizontal: gutter - LekisSpacing.sm,
                ),
              ),
            ),
          )
        else if (rows.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyPlaylistBody(isSmart: true),
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
            sliver: SliverFixedExtentList.builder(
              itemExtent: TrackTile.extent,
              itemCount: rows.length,
              itemBuilder: (context, i) => TrackTile(
                track: rows[i],
                onTap: () =>
                    playPlaylistContext(context, playlist, startIndex: i),
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

class _PlaylistHeader extends ConsumerWidget {
  const _PlaylistHeader({
    required this.playlist,
    required this.subtitle,
    required this.onPlay,
    this.onShuffle,
    this.onEditRules,
    this.onDownload,
    this.onExport,
    this.onSort,
    this.onCopy,
    this.onDedupe,
    this.onCleanMissing,
    this.onMerge,
    this.onSelect,
    this.queueTrackIds = const [],
  });

  final PlaylistDto playlist;
  final String subtitle;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final VoidCallback? onEditRules;
  final VoidCallback? onDownload;
  final VoidCallback? onExport;
  final VoidCallback? onSort;
  final VoidCallback? onCopy;
  final VoidCallback? onDedupe;
  final VoidCallback? onCleanMissing;
  final VoidCallback? onMerge;
  final VoidCallback? onSelect;

  /// 歌单里能播放的曲目，给"下一首播放 / 加入播放队列"用。
  final List<int> queueTrackIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;

    Future<void> delete() async {
      final deleted = await deletePlaylistFlow(context, ref, playlist);
      if (deleted && context.mounted) Navigator.of(context).maybePop();
    }

    Future<void> rename() async {
      await renamePlaylistFlow(context, ref, playlist);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 560;
        final art = PlaylistCover(
          playlist: playlist,
          size: wide ? 132 : 104,
          radius: LekisRadius.artworkGrid,
          iconSize: wide ? 52 : 42,
        );

        final info = Column(
          crossAxisAlignment: wide
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Semantics(
                    header: true,
                    child: Text(
                      playlist.name,
                      textAlign: wide ? TextAlign.start : TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: LekisSpacing.sm),
                PlaylistKindChip(playlist: playlist),
              ],
            ),
            const SizedBox(height: LekisSpacing.xs),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: LekisSpacing.lg),
            Wrap(
              alignment: wide ? WrapAlignment.start : WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: LekisSpacing.sm,
              runSpacing: LekisSpacing.sm,
              children: [
                FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(PlaylistStrings.play),
                ),
                if (onShuffle != null)
                  OutlinedButton.icon(
                    onPressed: onShuffle,
                    icon: const Icon(Icons.shuffle_rounded),
                    label: Text(PlaylistStrings.shufflePlay),
                  ),
                if (onEditRules != null)
                  OutlinedButton.icon(
                    onPressed: onEditRules,
                    icon: const Icon(Icons.tune_rounded),
                    label: Text(PlaylistStrings.editRules),
                  ),
                if (onDownload != null)
                  OutlinedButton.icon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download_for_offline_outlined),
                    label: Text(PlaylistStrings.downloadPlaylist),
                  ),
                if (onExport != null)
                  OutlinedButton.icon(
                    onPressed: onExport,
                    icon: const Icon(Icons.ios_share_rounded),
                    label: Text(PlaylistStrings.exportPlaylist),
                  ),
                LekisActionMenuButton<String>(
                  title: playlist.name,
                  tooltip: PlaylistStrings.playlistActions,
                  onSelected: (value) {
                    switch (value) {
                      case 'next':
                        queueTracks(
                          context,
                          queueTrackIds,
                          where: QueuePlacement.next,
                        );
                      case 'queue':
                        queueTracks(
                          context,
                          queueTrackIds,
                          where: QueuePlacement.end,
                        );
                      case 'cover':
                        changePlaylistCoverFlow(
                          context,
                          playlistId: playlist.id.toInt(),
                          previousArtworkId: playlist.artworkId?.toInt(),
                        );
                      case 'cover-remove':
                        changePlaylistCoverFlow(
                          context,
                          playlistId: playlist.id.toInt(),
                          previousArtworkId: playlist.artworkId?.toInt(),
                          pick: false,
                        );
                      case 'rename':
                        rename();
                      case 'duplicate':
                        unawaited(
                          duplicatePlaylistFlow(context, ref, playlist),
                        );
                      case 'sort':
                        onSort?.call();
                      case 'copy':
                        onCopy?.call();
                      case 'dedupe':
                        onDedupe?.call();
                      case 'missing':
                        onCleanMissing?.call();
                      case 'merge':
                        onMerge?.call();
                      case 'select':
                        onSelect?.call();
                      case 'delete':
                        delete();
                    }
                  },
                  actions: () => [
                    if (queueTrackIds.isNotEmpty) ...[
                      LekisMenuAction(
                        'next',
                        Icons.queue_play_next,
                        QueueStrings.playNext,
                      ),
                      LekisMenuAction(
                        'queue',
                        Icons.add_to_queue,
                        QueueStrings.addToQueue,
                      ),
                    ],
                    LekisMenuAction(
                      'cover',
                      Icons.image_outlined,
                      ArtworkActionStrings.change,
                      startsGroup: true,
                    ),
                    if (playlist.artworkId != null)
                      LekisMenuAction(
                        'cover-remove',
                        Icons.hide_image_outlined,
                        ArtworkActionStrings.remove,
                      ),
                    LekisMenuAction(
                      'rename',
                      Icons.edit_outlined,
                      PlaylistStrings.rename,
                    ),
                    LekisMenuAction(
                      'duplicate',
                      Icons.content_copy,
                      PlaylistStrings.duplicate,
                    ),
                    if (onSort != null)
                      LekisMenuAction(
                        'sort',
                        Icons.sort,
                        PlaylistStrings.sortPlaylist,
                        startsGroup: true,
                      ),
                    if (onCopy != null)
                      LekisMenuAction(
                        'copy',
                        Icons.playlist_add,
                        PlaylistStrings.copyPlaylist,
                      ),
                    if (onDedupe != null)
                      LekisMenuAction(
                        'dedupe',
                        Icons.filter_list,
                        PlaylistStrings.removeDuplicates,
                      ),
                    if (onCleanMissing != null)
                      LekisMenuAction(
                        'missing',
                        Icons.playlist_remove,
                        PlaylistStrings.removeMissing,
                      ),
                    if (onMerge != null)
                      LekisMenuAction(
                        'merge',
                        Icons.merge,
                        PlaylistStrings.mergePlaylist,
                      ),
                    if (onSelect != null)
                      LekisMenuAction(
                        'select',
                        Icons.checklist,
                        PlaylistStrings.selectEntries,
                      ),
                    LekisMenuAction(
                      'delete',
                      Icons.delete_outline,
                      PlaylistStrings.deletePlaylist,
                      startsGroup: true,
                      destructive: true,
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        if (!wide) {
          return Column(
            children: [
              art,
              const SizedBox(height: LekisSpacing.lg),
              info,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            art,
            const SizedBox(width: LekisSpacing.xl),
            Expanded(child: info),
          ],
        );
      },
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.visibleCount,
    required this.allVisibleSelected,
    required this.onToggleVisible,
    required this.onCancel,
    required this.onRemove,
  });

  final int count;
  final int visibleCount;
  final bool allVisibleSelected;
  final VoidCallback? onToggleVisible;
  final VoidCallback onCancel;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Material(
      elevation: 8,
      color: colors.surfaceElevated,
      borderRadius: BorderRadius.circular(LekisRadius.lg),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.md,
          vertical: LekisSpacing.sm,
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: LekisSpacing.sm,
          runSpacing: LekisSpacing.xs,
          children: [
            Text(
              context.l10n.pick('已选 $count 首', '$count selected'),
              style: theme.textTheme.bodyMedium,
            ),
            IconButton(
              tooltip: allVisibleSelected
                  ? context.l10n.pick(
                      '取消选择当前 $visibleCount 项',
                      'Deselect $visibleCount listed entries',
                    )
                  : context.l10n.pick(
                      '全选当前 $visibleCount 项',
                      'Select all $visibleCount listed entries',
                    ),
              icon: Icon(
                allVisibleSelected
                    ? Icons.deselect_rounded
                    : Icons.select_all_rounded,
              ),
              onPressed: onToggleVisible,
            ),
            TextButton(
              onPressed: onCancel,
              child: Text(PlaylistStrings.cancel),
            ),
            FilledButton.icon(
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(PlaylistStrings.removeSelected),
            ),
          ],
        ),
      ),
    );
  }
}

/// Entries of a static playlist. Moves slide the two rows past each other,
/// removals collapse the row before the core is asked, and rows that the
/// refreshed list adds fade in.
class _PlaylistEntryList extends StatefulWidget {
  const _PlaylistEntryList({
    required this.playlist,
    required this.rows,
    required this.busy,
    required this.selecting,
    required this.selectedKeys,
    required this.onToggleSelect,
    required this.onMove,
    required this.onRemove,
    required this.onMoveToTop,
    required this.onMoveToBottom,
    this.onPlayIndex,
  });

  final PlaylistDto playlist;
  final List<PlaylistEntryDto> rows;
  final bool busy;
  final bool selecting;
  final Set<String> selectedKeys;
  final ValueChanged<PlaylistEntryDto> onToggleSelect;
  final Future<void> Function(
    List<PlaylistEntryDto> entries,
    int index,
    bool up,
  )
  onMove;
  final Future<void> Function(PlaylistEntryDto entry) onRemove;
  final Future<void> Function(PlaylistEntryDto entry) onMoveToTop;
  final Future<void> Function(PlaylistEntryDto entry) onMoveToBottom;
  final void Function(int index)? onPlayIndex;

  @override
  State<_PlaylistEntryList> createState() => _PlaylistEntryListState();
}

class _PlaylistEntryListState extends State<_PlaylistEntryList>
    with SingleTickerProviderStateMixin {
  late final ListMotion _motion = ListMotion(vsync: this);
  late List<Object> _keys = _keysOf(widget.rows);
  final Set<Object> _removing = <Object>{};
  Timer? _removeFallback;

  // Position keys change on every move; the track uid (plus occurrence for
  // repeats) is what stays put.
  static List<Object> _keysOf(List<PlaylistEntryDto> rows) =>
      occurrenceKeys(rows, (entry) => entry.trackUid);

  @override
  void didUpdateWidget(_PlaylistEntryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.rows, widget.rows)) return;
    final keys = _keysOf(widget.rows);
    // Collapsed rows already left the screen; diff without them.
    final shown = [
      for (final k in _keys)
        if (!_removing.contains(k)) k,
    ];
    _motion.listChanged(
      old: (i) => shown[i],
      oldLength: shown.length,
      now: (i) => keys[i],
      nowLength: keys.length,
      animate: !lekisReduceMotion(context),
    );
    final present = keys.toSet();
    _removing.removeWhere((k) => !present.contains(k));
    _keys = keys;
  }

  @override
  void dispose() {
    _removeFallback?.cancel();
    _motion.dispose();
    super.dispose();
  }

  Future<void> _remove(Object key, PlaylistEntryDto entry) async {
    if (_removing.contains(key)) return;
    setState(() => _removing.add(key));
    if (!lekisReduceMotion(context)) {
      await Future<void>.delayed(ListRowCollapse.duration);
    }
    if (!mounted) return;
    await widget.onRemove(entry);
    // Failed (the error was already shown): the row is still listed once
    // the refresh lands, so open it back up.
    _removeFallback?.cancel();
    _removeFallback = Timer(const Duration(seconds: 2), () {
      if (mounted && _removing.contains(key) && _keys.contains(key)) {
        setState(() => _removing.remove(key));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final busy = widget.busy;
    return SliverList.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final key = _keys[i];
        return ListMotionRow(
          key: ValueKey(key),
          motion: _motion,
          index: i,
          child: ListRowCollapse(
            collapsed: _removing.contains(key),
            child: _PlaylistEntryTile(
              entry: rows[i],
              index: i,
              selecting: widget.selecting,
              selected: widget.selectedKeys.contains(rows[i].positionKey),
              onToggleSelect: () => widget.onToggleSelect(rows[i]),
              canMoveUp: !busy && i > 0,
              canMoveDown: !busy && i < rows.length - 1,
              canMoveToTop: !busy && i > 0,
              canMoveToBottom: !busy && i < rows.length - 1,
              onPlay: rows[i].track == null
                  ? null
                  : widget.onPlayIndex != null
                  ? () => widget.onPlayIndex!(i)
                  : () => playPlaylistContext(
                      context,
                      widget.playlist,
                      startIndex: i,
                    ),
              onMoveUp: () => widget.onMove(rows, i, true),
              onMoveDown: () => widget.onMove(rows, i, false),
              onMoveToTop: () => widget.onMoveToTop(rows[i]),
              onMoveToBottom: () => widget.onMoveToBottom(rows[i]),
              onRemove: () => _remove(key, rows[i]),
            ),
          ),
        );
      },
    );
  }
}

class _PlaylistEntryTile extends StatelessWidget {
  const _PlaylistEntryTile({
    required this.entry,
    required this.index,
    required this.selecting,
    required this.selected,
    required this.onToggleSelect,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.canMoveToTop,
    required this.canMoveToBottom,
    required this.onPlay,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onMoveToTop,
    required this.onMoveToBottom,
    required this.onRemove,
  });

  final PlaylistEntryDto entry;
  final int index;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggleSelect;
  final bool canMoveUp;
  final bool canMoveDown;
  final bool canMoveToTop;
  final bool canMoveToBottom;
  final VoidCallback? onPlay;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onMoveToTop;
  final VoidCallback onMoveToBottom;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final track = entry.track;
    return InkWell(
      onTap: selecting ? onToggleSelect : onPlay,
      onLongPress: onToggleSelect,
      borderRadius: BorderRadius.circular(LekisRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.sm,
          vertical: LekisSpacing.xs,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Phones: the up / down arrows live only in the overflow menu
            // (which already has them), so the title is not squeezed.
            final compact = constraints.maxWidth < 560;
            return Row(
              children: [
                if (selecting)
                  SizedBox(
                    width: 32,
                    child: Checkbox(
                      value: selected,
                      onChanged: (_) => onToggleSelect(),
                    ),
                  ),
                SizedBox.square(
                  dimension: LekisSizes.listArtwork,
                  child: track == null
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surfaceVariant,
                            borderRadius: BorderRadius.circular(
                              LekisRadius.artworkList,
                            ),
                          ),
                          child: Icon(
                            Icons.music_off_rounded,
                            color: colors.onSurfaceVariant,
                          ),
                        )
                      : TrackArtwork(
                          trackId: track.id,
                          hasArtwork: track.artworkId != null || !track.isLocal,
                          placeholderLabel: track.title,
                        ),
                ),
                const SizedBox(width: LekisSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        track?.title ?? PlaylistStrings.trackUnavailable,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: track == null ? colors.onSurfaceVariant : null,
                        ),
                      ),
                      if (track != null && track.artistLine.isNotEmpty)
                        Text(
                          track.artistLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (track != null)
                  LovedButton(
                    trackId: track.id,
                    initialLoved: track.loved,
                    size: LekisSpacing.lg,
                  ),
                if (track != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LekisSpacing.xs,
                    ),
                    child: Text(
                      formatDuration(track.durationMs.toInt()),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                if (!compact) ...[
                  _MiniIconButton(
                    tooltip: PlaylistStrings.moveUp,
                    icon: Icons.keyboard_arrow_up_rounded,
                    onPressed: canMoveUp ? onMoveUp : null,
                  ),
                  _MiniIconButton(
                    tooltip: PlaylistStrings.moveDown,
                    icon: Icons.keyboard_arrow_down_rounded,
                    onPressed: canMoveDown ? onMoveDown : null,
                  ),
                ],
                LekisActionMenuButton<String>(
                  tooltip: PlaylistStrings.entryActions,
                  compact: true,
                  title: track?.title ?? PlaylistStrings.trackUnavailable,
                  onSelected: (value) {
                    switch (value) {
                      case 'up':
                        onMoveUp();
                      case 'down':
                        onMoveDown();
                      case 'top':
                        onMoveToTop();
                      case 'bottom':
                        onMoveToBottom();
                      case 'remove':
                        onRemove();
                    }
                  },
                  actions: () => [
                    LekisMenuAction(
                      'up',
                      Icons.arrow_upward_rounded,
                      PlaylistStrings.moveUp,
                      enabled: canMoveUp,
                    ),
                    LekisMenuAction(
                      'down',
                      Icons.arrow_downward_rounded,
                      PlaylistStrings.moveDown,
                      enabled: canMoveDown,
                    ),
                    LekisMenuAction(
                      'top',
                      Icons.vertical_align_top_rounded,
                      PlaylistStrings.moveToTop,
                      enabled: canMoveToTop,
                    ),
                    LekisMenuAction(
                      'bottom',
                      Icons.vertical_align_bottom_rounded,
                      PlaylistStrings.moveToBottom,
                      enabled: canMoveToBottom,
                    ),
                    LekisMenuAction(
                      'remove',
                      Icons.playlist_remove_rounded,
                      PlaylistStrings.removeFromPlaylist,
                      startsGroup: true,
                      destructive: true,
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MiniIconButton extends StatelessWidget {
  const _MiniIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    padding: EdgeInsets.zero,
    onPressed: onPressed,
    icon: Icon(icon, size: 20),
  );
}

class _EmptyPlaylistBody extends StatelessWidget {
  const _EmptyPlaylistBody({required this.isSmart});

  final bool isSmart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LekisSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Smart rules matched nothing → puzzled; a fresh playlist → lounging.
            LekisMascot(
              pose: isSmart
                  ? LekisMascotPose.thinking
                  : LekisMascotPose.sitting,
              size: 112,
            ),
            const SizedBox(height: LekisSpacing.md),
            Text(
              isSmart
                  ? PlaylistStrings.smartEmpty
                  : PlaylistStrings.staticEmpty,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
