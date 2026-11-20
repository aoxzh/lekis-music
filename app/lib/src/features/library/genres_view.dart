import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/album_detail_page.dart'
    show PlayShuffleButtons;
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/paged_track_list.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/features/library/widgets/press_feedback.dart';
import 'package:material_ui/material_ui.dart';

class GenreList extends ConsumerWidget {
  const GenreList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final genres = ref.watch(genresProvider);
    final gutter = pageGutterOf(context);
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return genres.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => LoadErrorView(
        error: e,
        onRetry: () => ref.invalidate(genresProvider),
      ),
      data: (genres) {
        if (genres.isEmpty) return const LibraryEmptyState();
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(
            gutter - LekisSpacing.sm,
            0,
            gutter - LekisSpacing.sm,
            scrollEndPadding(context),
          ),
          itemExtent: LekisSizes.touchTargetMin + LekisSpacing.sm,
          itemCount: genres.length,
          itemBuilder: (context, i) {
            final g = genres[i];
            return PressFeedback(
              child: InkWell(
                borderRadius: BorderRadius.circular(LekisRadius.sm),
                onTap: () =>
                    Navigator.of(context).push(GenreDetailPage.route(g.name)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LekisSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          g.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
                      Text(
                        '${g.trackCount}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          fontFeatures: LekisText.tabularFigures,
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
        );
      },
    );
  }
}

class GenreDetailPage extends ConsumerWidget {
  const GenreDetailPage({super.key, required this.genre});

  final String genre;

  static Route<void> route(String genre) => MaterialPageRoute<void>(
    settings: RouteSettings(name: '/genre/$genre'),
    builder: (_) => GenreDetailPage(genre: genre),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(genreTracksListProvider(genre));
    final actions = ref.read(playerActionsProvider);
    void playAll({bool shuffle = false}) {
      final (rows, _) = list.loadedWindow(0);
      actions.playRows(rows, shuffle: shuffle);
    }

    return Scaffold(
      appBar: AppBar(title: Text(genre)),
      body: PagedTrackList(
        list: list,
        header: Padding(
          padding: const EdgeInsets.all(LekisSpacing.lg),
          child: PlayShuffleButtons(
            onPlay: playAll,
            onShuffle: () => playAll(shuffle: true),
          ),
        ),
      ),
    );
  }
}
