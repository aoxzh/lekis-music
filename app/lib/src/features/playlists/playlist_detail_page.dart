// 歌单详情：普通歌单可增删 / 上下移动；智能歌单展示实时规则结果。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/library/artwork_actions.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart';
import 'package:lekis/src/features/playlists/playlist_cover.dart';
import 'package:lekis/src/features/playlists/playlist_m3u.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/features/playlists/smart_playlist_editor_page.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/nav_icon.dart' show lekisReduceMotion;
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/list_motion.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:lekis/src/features/player/queue_actions.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lekis/src/features/playlists/playlist_strings.dart';

class PlaylistDetailPage extends StatelessWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});

  final int playlistId;

  static Route<void> route(int playlistId) => MaterialPageRoute<void>(
    settings: RouteSettings(name: '/playlist/$playlistId'),
    builder: (_) => PlaylistDetailPage(playlistId: playlistId),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: PlaylistDetailView(playlistId: playlistId),
  );
}

class PlaylistDetailView extends ConsumerStatefulWidget {
  const PlaylistDetailView({super.key, required this.playlistId});

  final int playlistId;

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

class _StaticPlaylistBody extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(playlistEntriesProvider(playlist.id));
    final gutter = pageGutterOf(context);
    final rows = entries.value ?? const <PlaylistEntryDto>[];
    final playableIds = rows
        .where((entry) => entry.track != null)
        .map((entry) => entry.track!.id)
        .toList(growable: false);
    final downloadIds = rows
        .where((entry) => entry.track != null && !entry.track!.isLocal)
        .map((entry) => entry.track!.id)
        .toList(growable: false);
    var totalMs = 0;
    for (final entry in rows) {
      final track = entry.track;
      if (track != null) totalMs += track.durationMs.toInt();
    }
    final totalDuration = totalMs > 0 ? Duration(milliseconds: totalMs) : null;

    return CustomScrollView(
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
              onDownload: downloadIds.isEmpty
                  ? null
                  : () => startDownloads(context, ref, downloadIds),
              onExport: () => exportPlaylistM3uFlow(context, playlist),
              onSort: rows.length < 2
                  ? null
                  : () => showPlaylistSortSheet(context, ref, playlist, rows),
              queueTrackIds: playableIds,
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
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
            sliver: _PlaylistEntryList(
              playlist: playlist,
              rows: rows,
              busy: busy,
              onMove: onMove,
              onRemove: onRemove,
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.only(bottom: scrollEndPadding(context)),
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
    this.onEditRules,
    this.onDownload,
    this.onExport,
    this.onSort,
    this.queueTrackIds = const [],
  });

  final PlaylistDto playlist;
  final String subtitle;
  final VoidCallback? onPlay;
  final VoidCallback? onEditRules;
  final VoidCallback? onDownload;
  final VoidCallback? onExport;
  final VoidCallback? onSort;

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
                PopupMenuButton<String>(
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
                      case 'delete':
                        delete();
                    }
                  },
                  itemBuilder: (_) => [
                    if (queueTrackIds.isNotEmpty) ...[
                      PopupMenuItem(
                        value: 'next',
                        child: Text(QueueStrings.playNext),
                      ),
                      PopupMenuItem(
                        value: 'queue',
                        child: Text(QueueStrings.addToQueue),
                      ),
                      const PopupMenuDivider(),
                    ],
                    PopupMenuItem(
                      value: 'cover',
                      child: Text(ArtworkActionStrings.change),
                    ),
                    if (playlist.artworkId != null)
                      PopupMenuItem(
                        value: 'cover-remove',
                        child: Text(ArtworkActionStrings.remove),
                      ),
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(PlaylistStrings.rename),
                    ),
                    PopupMenuItem(
                      value: 'duplicate',
                      child: Text(PlaylistStrings.duplicate),
                    ),
                    if (onSort != null)
                      PopupMenuItem(
                        value: 'sort',
                        child: Text(PlaylistStrings.sortPlaylist),
                      ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(PlaylistStrings.deletePlaylist),
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

/// Entries of a static playlist. Moves slide the two rows past each other,
/// removals collapse the row before the core is asked, and rows that the
/// refreshed list adds fade in.
class _PlaylistEntryList extends StatefulWidget {
  const _PlaylistEntryList({
    required this.playlist,
    required this.rows,
    required this.busy,
    required this.onMove,
    required this.onRemove,
  });

  final PlaylistDto playlist;
  final List<PlaylistEntryDto> rows;
  final bool busy;
  final Future<void> Function(
    List<PlaylistEntryDto> entries,
    int index,
    bool up,
  )
  onMove;
  final Future<void> Function(PlaylistEntryDto entry) onRemove;

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
              canMoveUp: !busy && i > 0,
              canMoveDown: !busy && i < rows.length - 1,
              onPlay: rows[i].track == null
                  ? null
                  : () => playPlaylistContext(
                      context,
                      widget.playlist,
                      startIndex: i,
                    ),
              onMoveUp: () => widget.onMove(rows, i, true),
              onMoveDown: () => widget.onMove(rows, i, false),
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
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onPlay,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
  });

  final PlaylistEntryDto entry;
  final int index;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback? onPlay;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final track = entry.track;
    return InkWell(
      onTap: onPlay,
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
                PopupMenuButton<String>(
                  tooltip: PlaylistStrings.entryActions,
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    switch (value) {
                      case 'up':
                        onMoveUp();
                      case 'down':
                        onMoveDown();
                      case 'remove':
                        onRemove();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'up',
                      enabled: canMoveUp,
                      child: Text(PlaylistStrings.moveUp),
                    ),
                    PopupMenuItem(
                      value: 'down',
                      enabled: canMoveDown,
                      child: Text(PlaylistStrings.moveDown),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      child: Text(PlaylistStrings.removeFromPlaylist),
                    ),
                  ],
                  // A 36 dp row action, matching the heart.
                  child: const SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(Icons.more_vert, size: 20),
                  ),
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
      child: Text(
        isSmart ? PlaylistStrings.smartEmpty : PlaylistStrings.staticEmpty,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
