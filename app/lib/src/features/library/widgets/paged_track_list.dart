import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/tag_editor_dialog.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
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
  });

  final PagedList<TrackRowDto> list;
  final Widget? empty;

  /// Optional fixed widget above the rows (scrolls with them).
  final Widget? header;

  /// 列表为空时是否仍然显示 [header]（文件夹视图的目录列表就在 header 里）。
  final bool showHeaderWhenEmpty;

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

  void _play(int index) {
    // TODO(core): a "play this sorted library view from index N" call would
    // let the queue span the whole library; until then we send the loaded
    // window (up to ~3 pages) around the tapped row.
    final (rows, start) = widget.list.loadedWindow(index);
    ref.read(playerActionsProvider).playRows(rows, start: start);
  }

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutterOf(context);
    return ListenableBuilder(
      listenable: widget.list,
      builder: (context, _) {
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
        if (list.isInitialLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
          sliver: SliverFixedExtentList.builder(
            itemExtent: TrackTile.extent,
            itemCount: list.itemCount,
            itemBuilder: (context, i) {
              final row = list.itemAt(i);
              if (row == null) return const TrackTilePlaceholder();
              return TrackTile(
                track: row,
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
          child: CustomScrollView(
            controller: _controller,
            slivers: [
              if (widget.header != null)
                SliverToBoxAdapter(child: widget.header),
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
        );
        if (_selected.isEmpty) return content;
        return Stack(
          children: [
            Positioned.fill(child: content),
            Positioned(
              left: LekisSpacing.lg,
              right: LekisSpacing.lg,
              bottom: LekisSpacing.lg,
              child: SafeArea(
                top: false,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Material(
                    elevation: 8,
                    color: context.lekisColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(LekisRadius.lg),
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
                            '已选 ${_selected.length} 首',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          TextButton(
                            onPressed: _clearSelection,
                            child: const Text('取消选择'),
                          ),
                          FilledButton.icon(
                            onPressed: _editSelectedTags,
                            icon: const Icon(Icons.edit_note_rounded),
                            label: const Text('批量编辑标签'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
