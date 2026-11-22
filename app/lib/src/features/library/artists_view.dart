import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/alphabet_index_bar.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/press_feedback.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:material_ui/material_ui.dart';

/// Paged artist list (fixed row height).
class ArtistList extends ConsumerStatefulWidget {
  const ArtistList({super.key, required this.onOpen, this.selectedId});

  final void Function(int artistId) onOpen;
  final int? selectedId;

  static double get extent => LekisSizes.listArtwork + LekisSpacing.sm * 2;

  @override
  ConsumerState<ArtistList> createState() => _ArtistListState();
}

class _ArtistListState extends ConsumerState<ArtistList> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(artistsListProvider);
    final offsets = ref.watch(artistIndexOffsetsProvider).value;
    final gutter = pageGutterOf(context);
    return ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        final loading =
            list.isInitialLoading && list.error == null && !list.isEmpty;
        return LekisLoadingSwitcher(
          loading: loading,
          skeleton: SkeletonListView(
            padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
            itemHeight: ArtistList.extent,
            circle: true,
            subtitle: false,
          ),
          child: loading
              ? const SizedBox.shrink()
              : _body(context, list, offsets, gutter),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    PagedList<ArtistDto> list,
    List<LetterOffsetDto>? offsets,
    double gutter,
  ) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    if (list.error != null) {
      return LoadErrorView(error: list.error!, onRetry: list.retry);
    }
    if (list.isEmpty) return const LibraryEmptyState();
    final showIndex =
        offsets != null && offsets.length >= 2 && list.itemCount >= 15;
    final scrollView = Scrollbar(
      controller: _controller,
      interactive: true,
      child: LekisShimmer(
        child: ListView.builder(
          controller: _controller,
          padding: EdgeInsets.fromLTRB(
            gutter - LekisSpacing.sm,
            0,
            gutter - LekisSpacing.sm + (showIndex ? LekisSpacing.xl : 0),
            scrollEndPadding(context),
          ),
          itemExtent: ArtistList.extent,
          itemCount: list.itemCount,
          itemBuilder: (context, i) {
            final artist = list.itemAt(i);
            if (artist == null) {
              return SkeletonListTile(
                index: i,
                height: ArtistList.extent,
                circle: true,
                subtitle: false,
              );
            }
            final selected = artist.id == widget.selectedId;
            return PressFeedback(
              child: InkWell(
                borderRadius: BorderRadius.circular(LekisRadius.sm),
                onTap: () => widget.onOpen(artist.id),
                child: Ink(
                  decoration: BoxDecoration(
                    color: selected ? colors.accentSoft : null,
                    borderRadius: BorderRadius.circular(LekisRadius.sm),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: LekisSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      ArtistAvatar(name: artist.name),
                      const SizedBox(width: LekisSpacing.md),
                      Expanded(
                        child: Text(
                          artist.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    if (!showIndex) return scrollView;
    final flatChrome =
        ref.watch(tabBarStyleProvider).resolved == TabBarStyle.flat;
    return Stack(
      children: [
        Positioned.fill(child: scrollView),
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
                  itemExtent: ArtistList.extent,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
