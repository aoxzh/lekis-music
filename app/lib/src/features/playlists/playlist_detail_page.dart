// 歌单详情：普通歌单可增删 / 上下移动；智能歌单展示实时规则结果。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart';
import 'package:lekis/src/features/playlists/playlist_m3u.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/features/playlists/smart_playlist_editor_page.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

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
      return Center(child: Text('歌单加载失败：${describeCoreError(loaded.error!)}'));
    }
    final playlist = loaded.value;
    if (playlist == null) {
      return const Center(child: CircularProgressIndicator());
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
              subtitle:
                  '${rows.isEmpty ? playlist.trackCount : rows.length} 首'
                  ' · 可上下移动条目',
              onPlay: rows.any((e) => e.track != null)
                  ? () => playPlaylistContext(context, playlist)
                  : null,
              onExport: () => exportPlaylistM3uFlow(context, playlist),
            ),
          ),
        ),
        if (entries.hasError)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(gutter),
              child: Text('条目加载失败：${describeCoreError(entries.error!)}'),
            ),
          )
        else if (entries.isLoading && rows.isEmpty)
          const SliverToBoxAdapter(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (rows.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyPlaylistBody(isSmart: false),
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
            sliver: SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) => _PlaylistEntryTile(
                entry: rows[i],
                index: i,
                canMoveUp: !busy && i > 0,
                canMoveDown: !busy && i < rows.length - 1,
                onPlay: rows[i].track == null
                    ? null
                    : () =>
                          playPlaylistContext(context, playlist, startIndex: i),
                onMoveUp: () => onMove(rows, i, true),
                onMoveDown: () => onMove(rows, i, false),
                onRemove: () => onRemove(rows[i]),
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
                  ? '智能歌单 · 规则实时求值'
                  : '智能歌单 · 已匹配 ${rows.length}${rows.length >= 5000 ? '+' : ''} 首',
              onPlay: rows.isEmpty
                  ? null
                  : () => playPlaylistContext(context, playlist),
              onEditRules: () => Navigator.of(context).push(
                SmartPlaylistEditorPage.route(playlist.id, name: playlist.name),
              ),
            ),
          ),
        ),
        if (tracks.hasError)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(gutter),
              child: Text('规则求值失败：${describeCoreError(tracks.error!)}'),
            ),
          )
        else if (tracks.isLoading && rows.isEmpty)
          const SliverToBoxAdapter(
            child: Center(child: CircularProgressIndicator()),
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
    this.onExport,
  });

  final PlaylistDto playlist;
  final String subtitle;
  final VoidCallback? onPlay;
  final VoidCallback? onEditRules;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final smart = playlist.kind == PlaylistKindDto.smart;

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
        final art = Container(
          width: wide ? 132 : 104,
          height: wide ? 132 : 104,
          decoration: BoxDecoration(
            color: smart
                ? colors.accentSoft
                : colors.surfaceVariant.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(LekisRadius.artworkGrid),
          ),
          child: Icon(
            smart ? Icons.auto_awesome_rounded : Icons.queue_music_rounded,
            size: wide ? 52 : 42,
            color: smart ? colors.accent : colors.onSurfaceVariant,
          ),
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
                  label: const Text('播放'),
                ),
                if (onEditRules != null)
                  OutlinedButton.icon(
                    onPressed: onEditRules,
                    icon: const Icon(Icons.tune_rounded),
                    label: const Text('编辑规则'),
                  ),
                if (onExport != null)
                  OutlinedButton.icon(
                    onPressed: onExport,
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('导出歌单'),
                  ),
                PopupMenuButton<String>(
                  tooltip: '歌单操作',
                  onSelected: (value) {
                    switch (value) {
                      case 'rename':
                        rename();
                      case 'delete':
                        delete();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'delete', child: Text('删除歌单')),
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
        child: Row(
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
                      hasArtwork: track.artworkId != null,
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
                    track?.title ?? '（曲目暂时不可用）',
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
            _MiniIconButton(
              tooltip: '上移',
              icon: Icons.keyboard_arrow_up_rounded,
              onPressed: canMoveUp ? onMoveUp : null,
            ),
            _MiniIconButton(
              tooltip: '下移',
              icon: Icons.keyboard_arrow_down_rounded,
              onPressed: canMoveDown ? onMoveDown : null,
            ),
            PopupMenuButton<String>(
              tooltip: '条目操作',
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
                  child: const Text('上移'),
                ),
                PopupMenuItem(
                  value: 'down',
                  enabled: canMoveDown,
                  child: const Text('下移'),
                ),
                const PopupMenuItem(value: 'remove', child: Text('从歌单移除')),
              ],
            ),
          ],
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
        isSmart ? '规则还没有匹配到歌曲' : '歌单是空的，从歌曲行菜单里添加',
        style: theme.textTheme.bodyLarge?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
