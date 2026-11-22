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

/// Columns for an album grid [width] wide (inside the gutters): the fewest
/// that keep every tile at most [albumGridMaxExtent], and never fewer than
/// two. Same rule as [SliverGridDelegateWithMaxCrossAxisExtent], computed
/// here so the cell height (cover + fixed text block) can be derived.
int albumGridColumns(double width) => math.max(
  2,
  ((width + LekisSpacing.lg) / (albumGridMaxExtent + LekisSpacing.lg)).ceil(),
);

/// Paged album grid.
class AlbumGrid extends ConsumerStatefulWidget {
  const AlbumGrid({super.key, required this.onOpen, this.selectedId});

  /// Hero scope of the grid's covers; open the page with
  /// `AlbumHeroTag(albumId, AlbumGrid.heroScope)` for a cover flight.
  static const Object heroScope = 'album-grid';

  final void Function(AlbumDto album) onOpen;
  final int? selectedId;

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
    final sort = ref.watch(albumSortProvider);
    final list = ref.watch(albumsListProvider(sort));
    final gutter = pageGutterOf(context);
    return ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        final loading =
            list.isInitialLoading && list.error == null && !list.isEmpty;
        return LekisLoadingSwitcher(
          loading: loading,
          skeleton: _grid(
            context,
            gutter,
            itemCount: 60,
            physics: const NeverScrollableScrollPhysics(),
            itemBuilder: (context, i) => SkeletonAlbumCard(index: i),
          ),
          child: loading
              ? const SizedBox.shrink()
              : _body(context, list, gutter),
        );
      },
    );
  }

  Widget _body(BuildContext context, PagedList<AlbumDto> list, double gutter) {
    if (list.error != null) {
      return LoadErrorView(error: list.error!, onRetry: list.retry);
    }
    if (list.isEmpty) return const LibraryEmptyState();
    return Scrollbar(
      controller: _controller,
      interactive: true,
      // Cells of pages still loading shimmer from one shared ticker.
      child: LekisShimmer(
        child: _grid(
          context,
          gutter,
          controller: _controller,
          itemCount: list.itemCount,
          itemBuilder: (context, i) {
            final album = list.itemAt(i);
            if (album == null) return SkeletonAlbumCard(index: i);
            return AlbumCard(
              album: album,
              selected: album.id == widget.selectedId,
              heroTag: AlbumHeroTag(album.id, AlbumGrid.heroScope),
              onTap: () => widget.onOpen(album),
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
    required int itemCount,
    required NullableIndexedWidgetBuilder itemBuilder,
    ScrollController? controller,
    ScrollPhysics? physics,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final usable = constraints.maxWidth - gutter * 2;
        final cols = albumGridColumns(usable);
        final cellWidth = ((usable - LekisSpacing.lg * (cols - 1)) / cols)
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
            mainAxisSpacing: LekisSpacing.lg,
            crossAxisSpacing: LekisSpacing.lg,
            childAspectRatio: cellWidth / cellHeight,
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}
