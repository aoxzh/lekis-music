import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/features/library/widgets/press_feedback.dart';
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
    final gutter = pageGutterOf(context);
    final theme = Theme.of(context);
    final colors = context.lekisColors;
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
        return Scrollbar(
          controller: _controller,
          interactive: true,
          child: ListView.builder(
            controller: _controller,
            padding: EdgeInsets.fromLTRB(
              gutter - LekisSpacing.sm,
              0,
              gutter - LekisSpacing.sm,
              LekisSpacing.xl,
            ),
            itemExtent: ArtistList.extent,
            itemCount: list.itemCount,
            itemBuilder: (context, i) {
              final artist = list.itemAt(i);
              if (artist == null) return const SizedBox.shrink();
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
        );
      },
    );
  }
}
