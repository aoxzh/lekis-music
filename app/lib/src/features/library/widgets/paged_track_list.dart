import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/tag_editor_dialog.dart';
import 'package:lekis/src/features/library/widgets/alphabet_index_bar.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_actions.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/liquid_glass.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:material_ui/material_ui.dart';

/// A song list over a [PagedList] that stays smooth at 100k+ rows:
/// fixed `itemExtent`, pages fetched on demand, small thumbnails only.
class PagedTrackList extends ConsumerStatefulWidget {
  const PagedTrackList({
    super.key,
    required this.list,
    this.empty,
    this.header,
    this.showHeaderWhenEmpty = false,
    this.indexOffsets,
    this.playContext,
    this.pluginId,
  });

  final PagedList<TrackRowDto> list;
  final Widget? empty;

  /// Optional fixed widget above the rows (scrolls with them).
  final Widget? header;

  /// 列表为空时是否仍然显示 [header]（文件夹视图的目录列表就在 header 里）。
  final bool showHeaderWhenEmpty;

  /// 首字母快速索引偏移（仅在按标题排序的长列表上传入，UIX-05）。
  final List<LetterOffsetDto>? indexOffsets;

  /// 列表对应的核心播放上下文。传入后，点击任意一行会从该行在完整
  /// 上下文中的位置开播，而不是只播放已加载的几页。
  final PlayContextDto? playContext;
  final String? pluginId;

  @override
  ConsumerState<PagedTrackList> createState() => _PagedTrackListState();
}

class _PagedTrackListState extends ConsumerState<PagedTrackList> {
  final _controller = ScrollController();
  final Set<int> _selected = <int>{};

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleSelected(int trackId) {
    setState(() {
      if (!_selected.add(trackId)) _selected.remove(trackId);
    });
  }

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(_selected.clear);
  }

  void _onRowTap(int index, int trackId) {
    if (_selected.isNotEmpty) {
      _toggleSelected(trackId);
    } else {
      _play(index);
    }
  }

  Future<void> _editSelectedTags() async {
    final ids = _selected.toList(growable: false);
    if (ids.isEmpty) return;
    await showBatchTagEditor(context, trackIds: ids);
    if (mounted) _clearSelection();
  }

  void _queueSelected(QueuePlacement where) {
    final ids = _selected.toList(growable: false);
    if (ids.isEmpty) return;
    queueTracks(context, ids, where: where);
    _clearSelection();
  }

  Future<void> _addSelectedToPlaylist() async {
    final ids = _selected.toList(growable: false);
    if (ids.isEmpty) return;
    final added = await showAddTracksToPlaylistSheet(
      context,
      ref,
      trackIds: ids,
    );
    if (mounted && added) _clearSelection();
  }

  void _play(int index) {
    final context = widget.playContext;
    if (context != null) {
      // The core expands the whole context itself, so a 100k-row library
      // does not need every id materialised in Dart.
      unawaited(
        ref.read(playerActionsProvider).playContext(context, startIndex: index),
      );
      return;
    }
    // Fallback for callers without a core context: play the loaded window
    // (up to ~3 pages) around the tapped row.
    final (rows, start) = widget.list.loadedWindow(index);
    ref.read(playerActionsProvider).playRows(rows, start: start);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.list,
      builder: (context, _) {
        final list = widget.list;
        final loading =
            list.isInitialLoading && list.error == null && !list.isEmpty;
        return LekisLoadingSwitcher(
          loading: loading,
          skeleton: SkeletonTrackListView(header: widget.header),
          child: loading ? const SizedBox.shrink() : _body(context),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    final gutter = pageGutterOf(context);
    final list = widget.list;
    if (list.error != null) {
      return LoadErrorView(error: list.error!, onRetry: list.retry);
    }
    if (list.isEmpty) {
      final empty = widget.empty ?? const LibraryEmptyState();
      if (widget.showHeaderWhenEmpty && widget.header != null) {
        return Scrollbar(
          controller: _controller,
          child: ListView(
            controller: _controller,
            padding: EdgeInsets.only(bottom: scrollEndPadding(context)),
            children: [widget.header!, empty],
          ),
        );
      }
      return empty;
    }
    final offsets = widget.indexOffsets;
    final showIndex =
        offsets != null && offsets.length >= 2 && list.itemCount >= 15;
    final rows = SliverPadding(
      padding: EdgeInsets.fromLTRB(
        gutter - LekisSpacing.sm,
        0,
        gutter - LekisSpacing.sm + (showIndex ? LekisSpacing.xl : 0),
        0,
      ),
      sliver: SliverFixedExtentList.builder(
        itemExtent: TrackTile.extent,
        itemCount: list.itemCount,
        itemBuilder: (context, i) {
          final row = list.itemAt(i);
          if (row == null) return SkeletonTrackTile(index: i);
          return TrackTile(
            track: row,
            onlinePlugin: widget.pluginId != null,
            pluginId: widget.pluginId,
            selected: _selected.contains(row.id),
            onTap: () => _onRowTap(i, row.id),
            onLongPress: () => _toggleSelected(row.id),
          );
        },
      ),
    );
    final content = Scrollbar(
      controller: _controller,
      interactive: true,
      // Rows of pages still loading shimmer from one shared ticker.
      child: LekisShimmer(
        child: CustomScrollView(
          controller: _controller,
          slivers: [
            if (widget.header != null) SliverToBoxAdapter(child: widget.header),
            rows,
            SliverPadding(
              // 选择模式下底部浮着操作条，再多留出它的高度。
              padding: EdgeInsets.only(
                bottom:
                    scrollEndPadding(context) +
                    (_selected.isEmpty
                        ? 0
                        : LekisSizes.touchTargetMin + LekisSpacing.xl),
              ),
            ),
          ],
        ),
      ),
    );
    final flatChrome =
        (_selected.isNotEmpty || showIndex) &&
        ref.watch(tabBarStyleProvider).resolved == TabBarStyle.flat;
    return Stack(
      children: [
        Positioned.fill(child: content),
        if (showIndex)
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.only(bottom: scrollEndPadding(context)),
                child: AlphabetIndexBar(
                  offsets: offsets,
                  flat: flatChrome,
                  onSelect: (row) => jumpScrollControllerToRow(
                    _controller,
                    rowIndex: row,
                    itemExtent: TrackTile.extent,
                  ),
                ),
              ),
            ),
          ),
        if (_selected.isNotEmpty)
          Positioned(
            left: LekisSpacing.lg,
            right: LekisSpacing.lg,
            bottom: LekisSpacing.lg,
            child: SafeArea(
              top: false,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: LekisGlassCapsule(
                  radius: LekisRadius.lg,
                  flat: flatChrome,
                  enableLens: false,
                  child: Material(
                    type: MaterialType.transparency,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LekisSpacing.md,
                        vertical: LekisSpacing.sm,
                      ),
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.center,
                        spacing: LekisSpacing.sm,
                        runSpacing: LekisSpacing.xs,
                        children: [
                          Text(
                            context.l10n.pick(
                              '已选 ${_selected.length} 首',
                              '${_selected.length} selected',
                            ),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          TextButton(
                            onPressed: _clearSelection,
                            child: Text(context.l10n.pick('取消选择', 'Clear')),
                          ),
                          OutlinedButton.icon(
                            onPressed: () =>
                                _queueSelected(QueuePlacement.next),
                            icon: const Icon(Icons.queue_play_next_rounded),
                            label: Text(QueueStrings.playNext),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _queueSelected(QueuePlacement.end),
                            icon: const Icon(Icons.add_to_queue_rounded),
                            label: Text(QueueStrings.addToQueue),
                          ),
                          OutlinedButton.icon(
                            onPressed: _addSelectedToPlaylist,
                            icon: const Icon(Icons.playlist_add_rounded),
                            label: Text(
                              context.l10n.pick('加入歌单', 'Add to Playlist'),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: _editSelectedTags,
                            icon: const Icon(Icons.edit_note_rounded),
                            label: Text(
                              context.l10n.pick('批量编辑标签', 'Batch Edit Tags'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
