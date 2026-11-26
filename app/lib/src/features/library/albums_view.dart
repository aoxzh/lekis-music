import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:material_ui/material_ui.dart';

/// Largest album tile side: wider windows get more columns instead of
/// bigger covers (the library is denser than Home).
const double albumGridMaxExtent = LekisSizes.gridArtworkMin;

/// Compact grid tile side: fits more albums per screen (3+ cols on phones).
const double albumCompactGridMaxExtent = 124;

/// Columns for an album grid [width] wide (inside the gutters): the fewest
/// that keep every tile at most [albumGridMaxExtent], and never fewer than
/// two. Same rule as [SliverGridDelegateWithMaxCrossAxisExtent], computed
/// here so the cell height (cover + fixed text block) can be derived.
int albumGridColumns(double width, {bool compact = false}) {
  final maxExtent = compact ? albumCompactGridMaxExtent : albumGridMaxExtent;
  final spacing = compact ? LekisSpacing.md : LekisSpacing.lg;
  final minCols = compact ? 3 : 2;
  return math.max(minCols, ((width + spacing) / (maxExtent + spacing)).ceil());
}

typedef AlbumMenuBuilder = Widget Function(
  BuildContext context,
  AlbumDto album,
  VoidCallback open,
);

/// Paged album view supporting standard grid, compact grid, and list layouts.
class AlbumGrid extends ConsumerStatefulWidget {
  const AlbumGrid({
    super.key,
    required this.onOpen,
    this.selectedId,
    this.menuBuilder,
    this.list,
    this.viewMode,
    this.empty = const LibraryEmptyState(),
  });

  /// Hero scope of the grid's covers; open the page with
  /// `AlbumHeroTag(albumId, AlbumGrid.heroScope)` for a cover flight.
  static const Object heroScope = 'album-grid';

  final void Function(AlbumDto album) onOpen;
  final int? selectedId;
  final AlbumMenuBuilder? menuBuilder;
  final PagedList<AlbumDto>? list;
  final AlbumViewMode? viewMode;
  final Widget empty;

  @override
  ConsumerState<AlbumGrid> createState() => _AlbumGridState();
}

class _AlbumGridState extends ConsumerState<AlbumGrid> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PagedList<AlbumDto> list =
        widget.list ??
        ref.watch(albumsListProvider(ref.watch(albumSortProvider)));
    final AlbumViewMode mode =
        widget.viewMode ?? ref.watch(albumViewModeProvider);
    final gutter = pageGutterOf(context);
    final listExtent = AlbumListTile.extentOf(context);
    return ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        final loading =
            list.isInitialLoading && list.error == null && !list.isEmpty;
        return LekisLoadingSwitcher(
          loading: loading,
          skeleton: mode == AlbumViewMode.list
              ? SkeletonListView(
                  padding: EdgeInsets.symmetric(
                    horizontal: gutter - LekisSpacing.sm,
                  ),
                  itemHeight: listExtent,
                )
              : _grid(
                  context,
                  gutter,
                  compact: mode == AlbumViewMode.compactGrid,
                  itemCount: 60,
                  physics: const NeverScrollableScrollPhysics(),
                  itemBuilder: (context, i) => SkeletonAlbumCard(index: i),
                ),
          child: loading
              ? const SizedBox.shrink()
              : _body(context, list, mode, gutter, listExtent),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    PagedList<AlbumDto> list,
    AlbumViewMode mode,
    double gutter,
    double listExtent,
  ) {
    if (list.error != null) {
      return LoadErrorView(error: list.error!, onRetry: list.retry);
    }
    if (list.isEmpty) return widget.empty;
    if (mode == AlbumViewMode.list) {
      return Scrollbar(
        controller: _controller,
        interactive: true,
        child: LekisShimmer(
          child: ListView.builder(
            controller: _controller,
            padding: EdgeInsets.fromLTRB(
              gutter - LekisSpacing.sm,
              LekisSpacing.xs,
              gutter - LekisSpacing.sm,
              scrollEndPadding(context),
            ),
            itemExtent: listExtent,
            itemCount: list.itemCount,
            itemBuilder: (context, i) {
              final album = list.itemAt(i);
              if (album == null) {
                return SkeletonListTile(
                  index: i,
                  height: listExtent,
                );
              }
              void open() => widget.onOpen(album);
              return AlbumListTile(
                album: album,
                useListedArtwork: widget.list != null,
                selected: album.id == widget.selectedId,
                heroTag: AlbumHeroTag(album.id, AlbumGrid.heroScope),
                onTap: open,
                menu: widget.menuBuilder?.call(context, album, open),
              );
            },
          ),
        ),
      );
    }
    final compact = mode == AlbumViewMode.compactGrid;
    return Scrollbar(
      controller: _controller,
      interactive: true,
      // Cells of pages still loading shimmer from one shared ticker.
      child: LekisShimmer(
        child: _grid(
          context,
          gutter,
          compact: compact,
          controller: _controller,
          itemCount: list.itemCount,
          itemBuilder: (context, i) {
            final album = list.itemAt(i);
            if (album == null) return SkeletonAlbumCard(index: i);
            void open() => widget.onOpen(album);
            return AlbumCard(
              album: album,
              useListedArtwork: widget.list != null,
              compact: compact,
              selected: album.id == widget.selectedId,
              heroTag: AlbumHeroTag(album.id, AlbumGrid.heroScope),
              onTap: open,
              menu: widget.menuBuilder?.call(context, album, open),
            );
          },
        ),
      ),
    );
  }

  /// The grid layout shared by the content and its skeleton, so cells land
  /// exactly where the skeleton cells were.
  Widget _grid(
    BuildContext context,
    double gutter, {
    required bool compact,
    required int itemCount,
    required NullableIndexedWidgetBuilder itemBuilder,
    ScrollController? controller,
    ScrollPhysics? physics,
  }) {
    final spacing = compact ? LekisSpacing.md : LekisSpacing.lg;
    return LayoutBuilder(
      builder: (context, constraints) {
        final usable = constraints.maxWidth - gutter * 2;
        final cols = albumGridColumns(usable, compact: compact);
        final cellWidth = ((usable - spacing * (cols - 1)) / cols)
            .clamp(1.0, double.infinity);
        final cellHeight =
            cellWidth + ArtworkCardFrame.textBlockHeight(context);
        return GridView.builder(
          controller: controller,
          physics: physics,
          padding: EdgeInsets.fromLTRB(
            gutter,
            LekisSpacing.sm,
            gutter,
            scrollEndPadding(context),
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: cellWidth / cellHeight,
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}
