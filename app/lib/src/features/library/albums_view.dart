import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Even column count (≥ 2) whose cells are at least [minExtent] wide, so a
/// vertical fold / two-pane split never cuts through an album card.
int evenColumnCount(double width, double minExtent) {
  var n = (width / minExtent).floor();
  if (n < 2) return 2;
  if (n.isOdd) n -= 1;
  return n;
}

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
            final cols = evenColumnCount(
              usable + LekisSpacing.lg,
              LekisSizes.gridArtworkMin + LekisSpacing.lg,
            );
            // Exactly `cols` columns: the delegate uses
            // ceil(width / (maxExtent + spacing)), so nudge just above.
            final maxExtent = (usable / cols - LekisSpacing.lg + 0.5).clamp(
              1.0,
              double.infinity,
            );
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
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: maxExtent,
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
