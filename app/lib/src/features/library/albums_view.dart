import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
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
        if (list.error != null) {
          return LoadErrorView(error: list.error!, onRetry: list.retry);
        }
        if (list.isEmpty) return const LibraryEmptyState();
        if (list.isInitialLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final usable = constraints.maxWidth - gutter * 2;
            final cols = albumGridColumns(usable);
            final cellWidth = ((usable - LekisSpacing.lg * (cols - 1)) / cols)
                .clamp(1.0, double.infinity);
            final cellHeight =
                cellWidth + ArtworkCardFrame.textBlockHeight(context);
            return Scrollbar(
              controller: _controller,
              interactive: true,
              child: GridView.builder(
                controller: _controller,
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
                itemCount: list.itemCount,
                itemBuilder: (context, i) {
                  final album = list.itemAt(i);
                  if (album == null) return const AlbumCardPlaceholder();
                  return AlbumCard(
                    album: album,
                    selected: album.id == widget.selectedId,
                    heroTag: AlbumHeroTag(album.id, AlbumGrid.heroScope),
                    onTap: () => widget.onOpen(album),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}
