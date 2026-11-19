import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
                padding: const EdgeInsets.only(bottom: LekisSpacing.xl),
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
              return TrackTile(track: row, onTap: () => _play(i));
            },
          ),
        );
        return Scrollbar(
          controller: _controller,
          interactive: true,
          child: CustomScrollView(
            controller: _controller,
            slivers: [
              if (widget.header != null)
                SliverToBoxAdapter(child: widget.header),
              rows,
              const SliverPadding(
                padding: EdgeInsets.only(bottom: LekisSpacing.xl),
              ),
            ],
          ),
        );
      },
    );
  }
}
