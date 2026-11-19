import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/shelf.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/search/search_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Search across songs, albums and artists (debounced).
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late final TextEditingController _text = TextEditingController(
    text: ref.read(searchQueryProvider),
  );

  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _set(String v) => ref.read(searchQueryProvider.notifier).set(v);

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutterOf(context);
    final query = ref.watch(searchQueryProvider);
    final results = ref.watch(searchResultsProvider);

    final field = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.lg,
        gutter,
        LekisSpacing.sm,
      ),
      child: SearchBar(
        controller: _text,
        autoFocus: _isDesktop,
        hintText: '歌曲、专辑、艺人',
        leading: const Icon(Icons.search_rounded),
        trailing: [
          if (query.isNotEmpty)
            IconButton(
              tooltip: '清除',
              onPressed: () {
                _text.clear();
                _set('');
              },
              icon: const Icon(Icons.close_rounded),
            ),
        ],
        onChanged: _set,
        onSubmitted: _set,
        textInputAction: TextInputAction.search,
      ),
    );

    Widget body;
    if (query.trim().isEmpty) {
      body = const _Hint(
        icon: Icons.search_rounded,
        text: '搜索你的资料库',
        message: '输入歌名、专辑、艺人，或直接输入拼音。',
      );
    } else {
      final data = results.value;
      if (data == null) {
        body = results.hasError && !results.isLoading
            ? LoadErrorView(
                error: results.error!,
                onRetry: () => ref.invalidate(searchResultsProvider),
              )
            : const Center(child: CircularProgressIndicator());
      } else if (data.tracks.isEmpty &&
          data.albums.isEmpty &&
          data.artists.isEmpty) {
        body = _Hint(
          icon: Icons.search_off_rounded,
          text: '没有找到“${query.trim()}”',
          message: '换一个关键词，或检查一下拼写。',
        );
      } else {
        body = _Results(results: data, stale: results.isLoading);
      }
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field,
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.results, required this.stale});

  final SearchResultsDto results;
  final bool stale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gutter = pageGutterOf(context);
    final theme = Theme.of(context);
    final tracks = results.tracks;
    Widget sectionTitle(String t) => Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.xl,
        gutter,
        LekisSpacing.sm,
      ),
      child: Semantics(
        header: true,
        child: Text(t, style: theme.textTheme.titleLarge),
      ),
    );

    return AnimatedOpacity(
      opacity: stale ? 0.6 : 1,
      duration: LekisMotion.fast,
      child: CustomScrollView(
        slivers: [
          if (tracks.isNotEmpty) SliverToBoxAdapter(child: sectionTitle('歌曲')),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
            sliver: SliverFixedExtentList.builder(
              itemExtent: TrackTile.extent,
              itemCount: tracks.length,
              itemBuilder: (context, i) => TrackTile(
                track: tracks[i],
                onTap: () =>
                    ref.read(playerActionsProvider).playRows(tracks, start: i),
              ),
            ),
          ),
          if (results.albums.isNotEmpty)
            SliverToBoxAdapter(
              child: ArtworkShelf(
                title: '专辑',
                itemCount: results.albums.length,
                itemBuilder: (context, i) => AlbumCard(
                  album: results.albums[i],
                  onTap: () =>
                      Navigator.of(context)
                          .push(AlbumDetailPage.route(results.albums[i].id)),
                ),
              ),
            ),
          if (results.artists.isNotEmpty)
            SliverToBoxAdapter(child: sectionTitle('艺人')),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: gutter - LekisSpacing.sm),
            sliver: SliverList.builder(
              itemCount: results.artists.length,
              itemBuilder: (context, i) {
                final a = results.artists[i];
                return ListTile(
                  minTileHeight: LekisSizes.touchTargetMin + LekisSpacing.md,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(LekisRadius.sm),
                  ),
                  leading: ArtistAvatar(name: a.name),
                  title: Text(a.name),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () =>
                      Navigator.of(context).push(ArtistDetailPage.route(a.id)),
                );
              },
            ),
          ),
          const SliverPadding(
            padding: EdgeInsets.only(bottom: LekisSpacing.xxl),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, this.message = ''});
  final IconData icon;
  final String text;
  final String message;

  @override
  Widget build(BuildContext context) =>
      LekisEmptyState(icon: icon, title: text, message: message);
}
