// 正在播放里的收藏 / 评分 / 下载 / 添加到歌单。
//

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/library_providers.dart'
    show artistIdForNameProvider;
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/now_playing/alternate_source_sheet.dart';
import 'package:lekis/src/features/now_playing/artwork_editor_sheet.dart';
import 'package:lekis/src/features/now_playing/lyrics_editor_sheet.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/now_playing/track_sources_sheet.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/video_action.dart';
import 'package:lekis/src/features/player/video_target.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/action_menu.dart';
import 'package:material_ui/material_ui.dart';

import '../connect/connect_strings.dart';
import '../connect/play_on_device.dart';

const BoxConstraints _touchTarget = BoxConstraints(
  minWidth: LekisSizes.touchTargetMin,
  minHeight: LekisSizes.touchTargetMin,
);

enum _MoreAction {
  alternateSource,
  video,
  videoExternal,
  rate,
  download,
  addToPlaylist,
  viewAlbum,
  viewArtist,
  playOnDevice,
  editArtwork,
  editLyrics,
  sources,
  copyInfo,
  copyLyrics,
  lyricsEarlier,
  lyricsLater,
  lyricsReset,
}

List<String> nowPlayingArtistNames(TrackDto track) => {
  for (final artist in track.artists)
    if (artist.trim().isNotEmpty) artist.trim(),
}.toList();

Future<void> openNowPlayingArtist(
  BuildContext context,
  WidgetRef ref,
  List<String> names,
) async {
  if (names.isEmpty) return;
  final name = names.length == 1
      ? names.single
      : await showLekisActionList<String>(
          context,
          title: context.l10n.pick('选择艺人', 'Choose an artist'),
          actions: [
            for (final artist in names)
              LekisMenuAction(artist, Icons.person_outline_rounded, artist),
          ],
        );
  if (!context.mounted || name == null) return;
  try {
    final id = await ref.read(artistIdForNameProvider(name).future);
    if (!context.mounted) return;
    if (id != null) {
      await Navigator.of(context).push(ArtistDetailPage.route(id));
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.pick('资料库里没有这位艺人', 'Artist not found in library'),
          ),
        ),
      );
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.pick('打开艺人失败：$error', 'Failed to open artist: $error'),
          ),
        ),
      );
  }
}

class NowPlayingLibraryActions extends ConsumerWidget {
  const NowPlayingLibraryActions({super.key, this.showRating = true});

  /// `false` on narrow columns: rating moves into the “more” menu so the
  /// title keeps its room.
  final bool showRating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).value;
    if (track == null) return const SizedBox.shrink();
    return Row(
      key: const ValueKey('now-playing.library-actions'),
      mainAxisSize: MainAxisSize.min,
      children: [
        CompactDownloadProgress(trackId: track.id),
        LovedButton(
          trackId: track.id,
          initialLoved: track.loved,
          size: LekisSpacing.xl,
          compact: false,
        ),
        if (showRating) _RatingButton(track: track),
        _MoreButton(track: track, includeRating: !showRating),
      ],
    );
  }
}

/// One star showing the current rating; opens the 1–5 star sheet.
class _RatingButton extends ConsumerWidget {
  const _RatingButton({required this.track});

  final TrackDto track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final rating = ratingOf(ref, track.id, track.rating?.toInt()) ?? 0;
    final rated = rating > 0;
    return IconButton(
      key: const ValueKey('now-playing.rating'),
      tooltip: rated
          ? context.l10n.pick('评分：$rating 星', 'Rating: $rating stars')
          : context.l10n.pick('评分', 'Rate'),
      constraints: _touchTarget,
      padding: EdgeInsets.zero,
      onPressed: () =>
          showTrackRatingSheet(context, trackId: track.id, title: track.title),
      icon: rated
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.star_rounded,
                  size: LekisSpacing.lg + LekisSpacing.xs,
                  color: colors.accent,
                ),
                Text(
                  '$rating',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.accent,
                    fontFeatures: LekisText.tabularFigures,
                  ),
                ),
              ],
            )
          : Icon(
              Icons.star_border_rounded,
              size: LekisSpacing.xl,
              color: colors.onSurfaceVariant,
            ),
    );
  }
}

/// Download and add-to-playlist (plus rating on narrow columns).
class _MoreButton extends ConsumerWidget {
  const _MoreButton({required this.track, required this.includeRating});

  final TrackDto track;
  final bool includeRating;

  Future<void> _copyInfo(BuildContext context) async {
    final text = [
      track.title,
      if (track.artists.isNotEmpty) track.artists.join(' / '),
      if (track.albumTitle != null && track.albumTitle!.isNotEmpty)
        track.albumTitle!,
    ].join(' — ');
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(context.l10n.pick('已复制曲目信息', 'Track info copied')),
          ),
        );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(context.l10n.pick('复制失败：$e', 'Copy failed: $e')),
          ),
        );
    }
  }

  Future<void> _openAlbum(BuildContext context) async {
    final albumId = track.albumId;
    if (albumId == null) return;
    await Navigator.of(context).push(AlbumDetailPage.route(albumId.toInt()));
  }

  Future<void> _copyLyrics(BuildContext context) async {
    try {
      final dto = await core.lyrics(trackId: track.id);
      final text = dto == null
          ? ''
          : ParsedLyrics.parse(dto).lines
                .map((line) => line.text)
                .where((line) => line.trim().isNotEmpty)
                .join('\n');
      if (text.trim().isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.pick('这首歌还没有歌词', 'No lyrics for this track'),
              ),
            ),
          );
        return;
      }
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.pick('已复制歌词', 'Lyrics copied'))),
        );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick('复制歌词失败：$e', 'Failed to copy lyrics: $e'),
            ),
          ),
        );
    }
  }

  Future<void> _adjustLyrics(
    BuildContext context,
    WidgetRef ref,
    int Function(int current) next,
  ) async {
    try {
      final current = await core.lyrics(trackId: track.id);
      if (current == null) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick('这首歌还没有歌词', 'No lyrics for this track'),
            ),
          ),
        );
        return;
      }
      final offset = next(current.offsetMs).clamp(-60000, 60000);
      await core.setLyricsOffset(trackId: track.id, offsetMs: offset);
      ref.invalidate(lyricsProvider(track.id));
      if (!context.mounted) return;
      final label = '${offset >= 0 ? '+' : ''}${offset}ms';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick('歌词偏移 $label', 'Lyrics offset $label'),
            ),
          ),
        );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.pick(
              '调整歌词偏移失败：$e',
              'Failed to adjust lyrics offset: $e',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadState = ref.watch(downloadStateProvider(track.id));
    final artists = nowPlayingArtistNames(track);
    final pluginTrack = PluginTrackRef.fromUid(track.uid) != null;
    final video =
        supportsVideo &&
        pluginSupportsVideo(ref, PluginTrackRef.fromUid(track.uid)?.pluginId) &&
        videoEnabled(ref);
    final rating = ratingOf(ref, track.id, track.rating?.toInt()) ?? 0;
    final missingCover = track.artworkId == null;
    return LekisActionMenuButton<_MoreAction>(
      key: const ValueKey('now-playing.more'),
      tooltip: context.l10n.pick('更多操作', 'More actions'),
      title: track.title,
      artwork: TrackArtwork(
        trackId: track.id,
        hasArtwork: track.artworkId != null || !track.isLocal,
        placeholderLabel: track.title,
      ),
      subtitle: artists.join(' / '),
      onSelected: (action) {
        switch (action) {
          case _MoreAction.alternateSource:
            showAlternateSourceSheet(context, track);
          case _MoreAction.video:
            unawaited(
              watchTrackVideo(
                context,
                trackId: track.id,
                uid: track.uid,
                title: track.title,
                artists: track.artists,
              ),
            );
          case _MoreAction.videoExternal:
            unawaited(
              watchTrackVideo(
                context,
                trackId: track.id,
                uid: track.uid,
                title: track.title,
                artists: track.artists,
                external: true,
              ),
            );
          case _MoreAction.rate:
            showTrackRatingSheet(
              context,
              trackId: track.id,
              title: track.title,
            );
          case _MoreAction.download:
            runDownloadMenuAction(context, ref, track.id, downloadState);
          case _MoreAction.addToPlaylist:
            showAddToPlaylistSheet(
              context,
              trackId: track.id,
              trackTitle: track.title,
            );
          case _MoreAction.viewAlbum:
            unawaited(_openAlbum(context));
          case _MoreAction.viewArtist:
            unawaited(openNowPlayingArtist(context, ref, artists));
          case _MoreAction.playOnDevice:
            showPlayOnDeviceSheet(context, ref);
          case _MoreAction.editArtwork:
            showArtworkEditor(context, ref, track);
          case _MoreAction.editLyrics:
            showLyricsEditor(context, ref, track.id);
          case _MoreAction.sources:
            showTrackSourcesSheet(
              context,
              trackId: track.id,
              title: track.title,
            );
          case _MoreAction.copyInfo:
            unawaited(_copyInfo(context));
          case _MoreAction.copyLyrics:
            unawaited(_copyLyrics(context));
          case _MoreAction.lyricsEarlier:
            unawaited(_adjustLyrics(context, ref, (offset) => offset + 500));
          case _MoreAction.lyricsLater:
            unawaited(_adjustLyrics(context, ref, (offset) => offset - 500));
          case _MoreAction.lyricsReset:
            unawaited(_adjustLyrics(context, ref, (_) => 0));
        }
      },
      actions: () => [
        if (video)
          LekisMenuAction(
            _MoreAction.video,
            Icons.ondemand_video_rounded,
            watchVideoLabel(context),
          ),
        if (video)
          LekisMenuAction(
            _MoreAction.videoExternal,
            Icons.open_in_new_rounded,
            openVideoInBrowserLabel(context),
          ),
        if (!track.isLocal && track.id > 0)
          LekisMenuAction(
            _MoreAction.alternateSource,
            Icons.swap_horiz_rounded,
            context.l10n.pick('手动换源', 'Change audio source'),
          ),
        if (includeRating)
          LekisMenuAction(
            _MoreAction.rate,
            rating > 0 ? Icons.star_rounded : Icons.star_outline_rounded,
            rating > 0
                ? context.l10n.pick('评分（$rating 星）', 'Rate ($rating stars)')
                : context.l10n.pick('评分', 'Rate'),
          ),
        if (!track.isLocal || downloadState != null)
          LekisMenuAction(_MoreAction.download, switch (downloadState) {
            null => Icons.download_for_offline_outlined,
            OfflineStateDto.ready => Icons.delete_outline_rounded,
            OfflineStateDto.failed => Icons.refresh_rounded,
            OfflineStateDto.downloading => Icons.close_rounded,
            OfflineStateDto.queued => Icons.download_rounded,
          }, downloadMenuLabel(downloadState)),
        LekisMenuAction(
          _MoreAction.addToPlaylist,
          Icons.playlist_add_rounded,
          context.l10n.pick('添加到歌单', 'Add to Playlist'),
          startsGroup: true,
        ),
        if (track.albumId != null)
          LekisMenuAction(
            _MoreAction.viewAlbum,
            Icons.album_outlined,
            context.l10n.pick('查看专辑', 'View Album'),
          ),
        if (artists.isNotEmpty)
          LekisMenuAction(
            _MoreAction.viewArtist,
            Icons.person_outline_rounded,
            context.l10n.pick('查看艺人', 'View Artist'),
          ),
        LekisMenuAction(
          _MoreAction.playOnDevice,
          Icons.cast_rounded,
          ConnectStrings.playHere,
        ),
        // Editors live in the menu, not as a floating button over the lyrics
        // (iOS 26 puts them with the rest of the lyric controls).
        if (!pluginTrack && track.id > 0)
          LekisMenuAction(
            _MoreAction.editArtwork,
            missingCover
                ? Icons.add_photo_alternate_outlined
                : Icons.image_outlined,
            missingCover
                ? context.l10n.pick('补全封面', 'Fetch & Edit Artwork')
                : context.l10n.pick('编辑封面', 'Edit Artwork'),
            startsGroup: true,
          ),
        LekisMenuAction(
          _MoreAction.editLyrics,
          Icons.edit_note_rounded,
          context.l10n.pick('编辑歌词', 'Edit Lyrics'),
          startsGroup: pluginTrack || track.id <= 0,
        ),
        LekisMenuAction(
          _MoreAction.sources,
          Icons.storage_rounded,
          context.l10n.pick('查看来源', 'View Sources'),
        ),
        LekisMenuAction(
          _MoreAction.copyInfo,
          Icons.copy_all_rounded,
          context.l10n.pick('复制曲目信息', 'Copy Track Info'),
        ),
        LekisMenuAction(
          _MoreAction.copyLyrics,
          Icons.content_copy_rounded,
          context.l10n.pick('复制歌词', 'Copy Lyrics'),
        ),
        LekisMenuAction(
          _MoreAction.lyricsEarlier,
          Icons.fast_rewind_rounded,
          context.l10n.pick('歌词提前 0.5 秒', 'Lyrics 0.5s earlier'),
          startsGroup: true,
        ),
        LekisMenuAction(
          _MoreAction.lyricsLater,
          Icons.fast_forward_rounded,
          context.l10n.pick('歌词延后 0.5 秒', 'Lyrics 0.5s later'),
        ),
        LekisMenuAction(
          _MoreAction.lyricsReset,
          Icons.restart_alt_rounded,
          context.l10n.pick('重置歌词偏移', 'Reset lyrics offset'),
        ),
      ],
    );
  }
}
