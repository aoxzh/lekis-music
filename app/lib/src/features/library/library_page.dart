import 'package:lekis/src/features/search/search_page.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/albums_view.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/artists_view.dart';
import 'package:lekis/src/features/library/folders_view.dart';
import 'package:lekis/src/features/library/genres_view.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/liked_view.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/paged_track_list.dart';
import 'package:lekis/src/features/playlists/playlists_view.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/layout/adaptive_two_pane.dart';
import 'package:lekis/src/layout/fold.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/liquid_glass.dart';
import 'package:material_ui/material_ui.dart';

/// Library: Albums / Artists / Songs / Genres.
///
/// On wide windows (and across a foldable's hinge) Albums and Artists show
/// one more level of hierarchy: the list on one side, the detail on the
/// other.
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final segment = ref.watch(librarySegmentProvider);
    final source = ref.watch(effectiveLibrarySourceProvider);
    ref.listen(librarySourcePluginsProvider, (_, plugins) {
      final selected = ref.read(librarySourceProvider);
      if (selected != null && !plugins.any((plugin) => plugin.id == selected)) {
        ref.read(librarySourceProvider.notifier).set(null);
        ref.read(selectedAlbumProvider.notifier).set(null);
        ref.read(selectedArtistProvider.notifier).set(null);
      }
    });
    final body = source != null
        ? SearchPage(key: ValueKey(source), pluginId: source)
        : switch (segment) {
            LibrarySegment.albums => const _AlbumsSegment(),
            LibrarySegment.artists => const _ArtistsSegment(),
            LibrarySegment.songs => const _SongsSegment(),
            LibrarySegment.genres => const GenreList(),
            LibrarySegment.playlists => const PlaylistsView(),
            LibrarySegment.liked => const LikedSongsView(),
            LibrarySegment.folders => const FoldersView(),
          };

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LibraryHeader(),
            Expanded(
              child: AnimatedSwitcher(
                duration: LekisMotion.fast,
                // A source change must immediately remove old playable rows.
                layoutBuilder: (current, _) =>
                    current ?? const SizedBox.shrink(),
                child: KeyedSubtree(
                  key: ValueKey((source, segment)),
                  child: body,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Library navigation and tools adapt to the width of the content pane.
/// A menu keeps all seven categories discoverable when a segmented row cannot fit.
class LibraryHeader extends ConsumerWidget {
  const LibraryHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final segment = ref.watch(librarySegmentProvider);
    final source = ref.watch(effectiveLibrarySourceProvider);
    final sources = ref.watch(librarySourcePluginsProvider);
    final gutter = pageGutterOf(context);
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final categories = <LibrarySegment, String>{
      LibrarySegment.albums: l10n.segAlbums,
      LibrarySegment.artists: l10n.segArtists,
      LibrarySegment.songs: l10n.segSongs,
      LibrarySegment.genres: l10n.segGenres,
      LibrarySegment.playlists: l10n.segPlaylists,
      LibrarySegment.liked: l10n.segLiked,
      LibrarySegment.folders: l10n.segFolders,
    };
    void select(LibrarySegment value) =>
        ref.read(librarySegmentProvider.notifier).set(value);

    final titleStyle = theme.textTheme.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
    );
    final title = Semantics(
      header: true,
      child: Text(
        l10n.navLibrary,
        key: const ValueKey('library-title'),
        style: titleStyle,
      ),
    );
    final tools = Row(
      key: const ValueKey('library-header-actions'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (sources.isNotEmpty) const _LibrarySourcePicker(),
        if (source == null && segment == LibrarySegment.albums)
          const _SortMenu(target: _SortTarget.albums),
        if (source == null && segment == LibrarySegment.albums)
          IconButton(
            tooltip: l10n.coverFlow,
            onPressed: () => openCoverFlow(context),
            icon: const Icon(Icons.view_carousel_rounded),
          ),
        if (source == null && segment == LibrarySegment.songs)
          const _SortMenu(target: _SortTarget.songs),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.lg,
        gutter,
        LekisSpacing.md,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          double textWidth(String text, TextStyle? style) {
            final painter = TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final width = painter.width;
            painter.dispose();
            return width;
          }

          final labelStyle =
              theme.segmentedButtonTheme.style?.textStyle?.resolve({
                WidgetState.selected,
              }) ??
              theme.textTheme.labelLarge;
          final labelWidth = categories.values
              .map((label) => textWidth(label, labelStyle))
              .reduce((a, b) => a > b ? a : b);
          // SegmentedButton gives each category the widest label's width.
          // Fit the actual localized/scaled text and reserve two touch targets.
          final navigationWidth =
              categories.length * (labelWidth + LekisSpacing.sm * 2);
          final requiredWidth =
              textWidth(l10n.navLibrary, titleStyle) +
              navigationWidth +
              2 * kMinInteractiveDimension +
              LekisSpacing.sm +
              LekisSpacing.lg;
          final wide =
              constraints.maxWidth >=
              requiredWidth + (sources.isEmpty ? 0 : 220);
          if (source != null) {
            return Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: LekisSpacing.lg,
              runSpacing: LekisSpacing.sm,
              children: [title, tools],
            );
          }
          if (wide) {
            return Row(
              children: [
                title,
                const Spacer(),
                SegmentedButton<LibrarySegment>(
                  key: const ValueKey('library-segments'),
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LekisSpacing.sm,
                    ),
                  ),
                  segments: [
                    for (final category in categories.entries)
                      ButtonSegment(
                        value: category.key,
                        label: Text(category.value),
                      ),
                  ],
                  selected: {segment},
                  onSelectionChanged: (values) => select(values.first),
                ),
                const SizedBox(width: LekisSpacing.sm),
                tools,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: LekisSpacing.lg,
                runSpacing: LekisSpacing.sm,
                children: [title, tools],
              ),
              const SizedBox(height: LekisSpacing.sm),
              DecoratedBox(
                decoration: ShapeDecoration(
                  color: context.lekisColors.accentSoft,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(LekisRadius.button),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LekisSpacing.md,
                  ),
                  child: Semantics(
                    label: l10n.pick('资料库分类', 'Library category'),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<LibrarySegment>(
                        key: const ValueKey('library-category-select'),
                        value: segment,
                        isExpanded: true,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                        icon: const Icon(Icons.expand_more_rounded),
                        items: [
                          for (final category in categories.entries)
                            DropdownMenuItem(
                              value: category.key,
                              child: Text(category.value),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) select(value);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LibrarySourcePicker extends ConsumerWidget {
  const _LibrarySourcePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(effectiveLibrarySourceProvider);
    final choices = [
      SettingsChoice('', context.l10n.pick('本地资料库', 'Local Library')),
      for (final plugin in ref.watch(librarySourcePluginsProvider))
        SettingsChoice(plugin.id, plugin.name),
    ];
    void select(String value) {
      ref.read(selectedAlbumProvider.notifier).set(null);
      ref.read(selectedArtistProvider.notifier).set(null);
      ref
          .read(librarySourceProvider.notifier)
          .set(value.isEmpty ? null : value);
    }

    return Semantics(
      label: context.l10n.pick('资料库音源', 'Library source'),
      child: SizedBox(
        key: const ValueKey('library-source-select'),
        width: 160,
        child: UiProfile.current.desktopSettings
            ? SettingsComboBox<String>(
                value: source ?? '',
                choices: choices,
                minWidth: 0,
                maxWidth: 160,
                onChanged: select,
              )
            : DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: source ?? '',
                  isExpanded: true,
                  borderRadius: BorderRadius.circular(LekisRadius.md),
                  items: [
                    for (final choice in choices)
                      DropdownMenuItem(
                        value: choice.value,
                        child: Text(
                          choice.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) select(value);
                  },
                ),
              ),
      ),
    );
  }
}

bool _showsTwoPanes(BuildContext context) =>
    isWideLayout(context) || context.fold.isSeparating;

class _AlbumsSegment extends ConsumerWidget {
  const _AlbumsSegment();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedAlbumProvider);
    final twoPane = _showsTwoPanes(context);
    return AdaptiveTwoPane(
      primaryFraction: 0.5,
      primary: AlbumGrid(
        selectedId: twoPane ? selected : null,
        onOpen: (album) {
          if (_showsTwoPanes(context)) {
            ref.read(selectedAlbumProvider.notifier).set(album.id);
          } else {
            Navigator.of(context).push(
              AlbumDetailPage.route(
                album.id,
                heroTag: AlbumHeroTag(album.id, AlbumGrid.heroScope),
                initialAlbum: album,
              ),
            );
          }
        },
      ),
      // The album grid is the page; the detail pane only opens once an
      // album is picked (an empty "pick one" half wasted a desktop window).
      // On a separating hinge the split stays so nothing sits on the crease.
      secondary: !twoPane
          ? null
          : selected != null
          ? _ClosablePane(
              onClose: () => ref.read(selectedAlbumProvider.notifier).set(null),
              child: AlbumDetailView(
                key: ValueKey(selected),
                albumId: selected,
              ),
            )
          : context.fold.isSeparating
          ? _PickPrompt(text: context.l10n.pick('选择一张专辑', 'Select an album'))
          : null,
    );
  }
}

/// A detail pane with a close button in its top trailing corner.
class _ClosablePane extends ConsumerWidget {
  const _ClosablePane({required this.onClose, required this.child});
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flat = ref.watch(tabBarStyleProvider).resolved == TabBarStyle.flat;
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: LekisSpacing.sm,
          right: LekisSpacing.sm,
          child: SafeArea(
            bottom: false,
            left: false,
            child: LekisGlassCapsule(
              radius: LekisRadius.pill,
              flat: flat,
              enableLens: false,
              child: IconButton(
                tooltip: context.l10n.pick('关闭', 'Close'),
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ArtistsSegment extends ConsumerWidget {
  const _ArtistsSegment();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedArtistProvider);
    final twoPane = _showsTwoPanes(context);
    return AdaptiveTwoPane(
      primaryFraction: 0.35,
      primary: ArtistList(
        selectedId: twoPane ? selected : null,
        onOpen: (id) {
          if (_showsTwoPanes(context)) {
            ref.read(selectedArtistProvider.notifier).set(id);
          } else {
            Navigator.of(context).push(ArtistDetailPage.route(id));
          }
        },
      ),
      secondary: twoPane
          ? (selected == null
                ? _PickPrompt(
                    text: context.l10n.pick('选择一位艺人', 'Select an artist'),
                  )
                : ArtistDetailView(key: ValueKey(selected), artistId: selected))
          : null,
    );
  }
}

class _SongsSegment extends ConsumerWidget {
  const _SongsSegment();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sort = ref.watch(songSortProvider);
    final indexOffsets = sort == TrackSortDto.title
        ? ref.watch(trackIndexOffsetsProvider).value
        : null;
    return PagedTrackList(
      key: ValueKey(sort),
      list: ref.watch(songsListProvider(sort)),
      indexOffsets: indexOffsets,
    );
  }
}

class _PickPrompt extends StatelessWidget {
  const _PickPrompt({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.touch_app_outlined,
            size: LekisSpacing.xxxl,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Text(
            text,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

enum _SortTarget { albums, songs }

class _SortMenu extends ConsumerWidget {
  const _SortMenu({required this.target});
  final _SortTarget target;

  static String _labelFor(BuildContext context, TrackSortDto sort) {
    final l10n = context.l10n;
    return switch (sort) {
      TrackSortDto.title => l10n.pick('标题', 'Title'),
      TrackSortDto.artist => l10n.pick('艺人', 'Artist'),
      TrackSortDto.album => l10n.pick('专辑', 'Album'),
      TrackSortDto.recentlyAdded => l10n.pick('最近添加', 'Recently Added'),
      TrackSortDto.mostPlayed => l10n.pick('最常播放', 'Most Played'),
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = target == _SortTarget.albums
        ? albumSortProvider
        : songSortProvider;
    final current = ref.watch(provider);
    final options = target == _SortTarget.albums
        ? const [
            TrackSortDto.title,
            TrackSortDto.artist,
            TrackSortDto.recentlyAdded,
          ]
        : TrackSortDto.values;
    return PopupMenuButton<TrackSortDto>(
      tooltip: context.l10n.pick(
        '排序：${_labelFor(context, current)}',
        'Sort: ${_labelFor(context, current)}',
      ),
      icon: const Icon(Icons.sort_rounded),
      initialValue: current,
      onSelected: (v) => ref.read(provider.notifier).set(v),
      itemBuilder: (_) => [
        for (final o in options)
          CheckedPopupMenuItem(
            value: o,
            checked: o == current,
            child: Text(_labelFor(context, o)),
          ),
      ],
    );
  }
}
