// Desktop playback queue: a 320 dp right-hand panel with the whole queue.
//
// It replaces the compact bottom sheet on expanded / wide windows and is also
// embedded as the third Now Playing pane (cover | controls | queue).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/library_providers.dart'
    show PagedList, artistIdForNameProvider;
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_move_next.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/l10n/duration_text.dart';
import 'package:lekis/src/layout/window_size.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/nav_icon.dart' show lekisReduceMotion;
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/list_motion.dart';
import 'package:lekis/src/widgets/progress_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// Paged queue list with current-item highlight and explicit row actions.
class QueuePanel extends ConsumerStatefulWidget {
  const QueuePanel({
    super.key,
    this.onClose,
    this.embedded = true,
    this.showHeader = true,
  });

  /// Width of the desktop queue panel.
  static const double width = LekisSizes.desktopQueuePanelWidth;

  /// Header close button (embedded pane / modal side panel). `null` hides it.
  final VoidCallback? onClose;

  /// Embedded panels paint a side border; modal panels rely on the dialog.
  final bool embedded;

  /// `false` nests the list under an existing tab header.
  final bool showHeader;

  /// Fixed row height; also used to jump to the current item.
  static const double rowExtent = LekisSizes.listArtwork + LekisSpacing.sm * 2;

  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  late final ListMotion _motion = ListMotion(vsync: this);

  /// The list on screen. Each queue edit rebuilds [queueListProvider]; the
  /// previous rows stay up until the new list has its first page, then the
  /// rows slide / fade to their new places instead of flashing a spinner.
  PagedList<TrackRowDto>? _shown;
  final Set<int> _removing = <int>{};
  Timer? _removeDelay;
  Timer? _removeFallback;
  bool _jumpedToCurrent = false;

  @override
  void dispose() {
    _removeDelay?.cancel();
    _removeFallback?.cancel();
    _scroll.dispose();
    _motion.dispose();
    super.dispose();
  }

  PagedList<TrackRowDto> _present(PagedList<TrackRowDto> latest) {
    final shown = _shown;
    if (identical(latest, shown)) return latest;
    if (shown == null) return _shown = latest;
    if (latest.isInitialLoading) return shown;
    if (latest.error == null) {
      _motion.listChanged(
        old: (i) => shown.itemAt(i)?.id,
        oldLength: shown.itemCount,
        now: (i) => latest.itemAt(i)?.id,
        nowLength: latest.itemCount,
        animate: !lekisReduceMotion(context),
      );
    }
    // Rows faded out for removal are gone from the new list.
    _removing.clear();
    return _shown = latest;
  }

  void _scheduleJump(int? currentIndex, int rowCount) {
    if (_jumpedToCurrent || currentIndex == null || rowCount == 0) return;
    _jumpedToCurrent = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = math.max(
        0.0,
        currentIndex * QueuePanel.rowExtent - QueuePanel.rowExtent * 2,
      );
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  void _jumpToCurrent(int? currentIndex) {
    if (currentIndex == null || !_scroll.hasClients) return;
    final target = math.max(
      0.0,
      currentIndex * QueuePanel.rowExtent - QueuePanel.rowExtent * 2,
    );
    final clamped = target
        .clamp(0.0, _scroll.position.maxScrollExtent)
        .toDouble();
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(clamped);
    } else {
      _scroll.animateTo(
        clamped,
        duration: LekisMotion.normal,
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _jumpToIndex(int index) {
    if (!_scroll.hasClients) return;
    final target = math.max(
      0.0,
      index * QueuePanel.rowExtent - QueuePanel.rowExtent * 2,
    );
    final clamped = target
        .clamp(0.0, _scroll.position.maxScrollExtent)
        .toDouble();
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(clamped);
    } else {
      _scroll.animateTo(
        clamped,
        duration: LekisMotion.normal,
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _findInQueue(BuildContext context) async {
    final length = ref.read(playbackProvider).queueLength;
    if (length == 0) return;
    final l10n = context.l10n;
    final controller = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.pick('在队列中查找', 'Find in Queue')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l10n.pick('歌名或艺人', 'Title or artist'),
          ),
          onSubmitted: (value) => Navigator.of(dialog).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(controller.text.trim()),
            child: Text(l10n.pick('查找', 'Find')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (query == null || query.isEmpty || !context.mounted) return;
    final needle = query.toLowerCase();
    var offset = 0;
    const pageSize = 200;
    while (offset < length) {
      final rows = await core.queueItems(offset: offset, limit: pageSize);
      if (rows.isEmpty) break;
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        if (row.title.toLowerCase().contains(needle) ||
            row.artistLine.toLowerCase().contains(needle)) {
          if (!mounted || !context.mounted) return;
          _jumpToIndex(offset + i);
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  l10n.pick('已定位到「${row.title}」', 'Jumped to "${row.title}"'),
                ),
              ),
            );
          return;
        }
      }
      offset += rows.length;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.pick('队列里没有找到「$query」', 'No queue match for "$query"'),
          ),
        ),
      );
  }

  Future<void> _clearUpcoming(BuildContext context) async {
    final playback = ref.read(playbackProvider);
    final current = playback.queueIndex;
    final length = playback.queueLength;
    if (current == null || current + 1 >= length) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(context.l10n.pick('没有未播放的曲目', 'No upcoming tracks')),
          ),
        );
      return;
    }
    final count = length - current - 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.pick('清除未播放曲目？', 'Clear upcoming tracks?')),
        content: Text(
          context.l10n.pick(
            '将移除当前曲目之后的 $count 首，当前播放不会停止。',
            'This removes the $count tracks after the current one; playback keeps going.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(context.l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(context.l10n.pick('清除', 'Clear')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    var failed = 0;
    try {
      for (var i = length - 1; i > current; i--) {
        try {
          core.queueRemove(index: i);
        } catch (_) {
          failed++;
        }
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                failed == 0
                    ? context.l10n.pick('已清除未播放曲目', 'Upcoming tracks cleared')
                    : context.l10n.pick(
                        '已清除，$failed 首失败',
                        'Cleared with $failed failures',
                      ),
              ),
            ),
          );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.pick('清除队列失败：$e', 'Failed to clear queue: $e'),
              ),
            ),
          );
      }
    }
  }

  Future<void> _shuffleUpcoming(BuildContext context) async {
    final playback = ref.read(playbackProvider);
    final current = playback.queueIndex;
    final length = playback.queueLength;
    if (current == null || current + 2 >= length) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick('没有足够的未播放曲目', 'Not enough upcoming tracks'),
            ),
          ),
        );
      return;
    }
    final count = length - current - 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.pick('打乱未播放曲目？', 'Shuffle upcoming tracks?')),
        content: Text(
          context.l10n.pick(
            '将随机重排当前曲目之后的 $count 首，当前播放不会中断。',
            'This randomly reorders the $count tracks after the current one; playback keeps going.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(context.l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(context.l10n.pick('打乱', 'Shuffle')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final random = math.Random();
    var failed = 0;
    try {
      for (var i = current + 1; i < length; i++) {
        final j = i + random.nextInt(length - i);
        if (j == i) continue;
        try {
          core.queueMove(from: j, to: i);
        } catch (_) {
          failed++;
        }
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                failed == 0
                    ? context.l10n.pick(
                        '已打乱 $count 首',
                        'Shuffled $count tracks',
                      )
                    : context.l10n.pick(
                        '已打乱，$failed 首失败',
                        'Shuffled with $failed failures',
                      ),
              ),
            ),
          );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.pick('打乱队列失败：$e', 'Failed to shuffle queue: $e'),
              ),
            ),
          );
      }
    }
  }

  Future<void> _dedupeQueue(BuildContext context) async {
    final playback = ref.read(playbackProvider);
    final current = playback.queueIndex;
    final length = playback.queueLength;
    if (length < 2) return;

    final progress = ValueNotifier<int>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => nonDismissibleProgressDialog(
          title: Text(context.l10n.pick('正在检查队列', 'Checking Queue')),
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: length == 0 ? 0 : done / length),
                const SizedBox(height: LekisSpacing.md),
                Text('$done / $length'),
              ],
            ),
          ),
        ),
      ),
    );

    final seen = <int>{};
    final duplicates = <int>[];
    try {
      var offset = 0;
      while (offset < length) {
        final page = await core.queueItems(
          offset: offset,
          limit: math.min(500, length - offset),
        );
        if (page.isEmpty) break;
        for (var i = 0; i < page.length; i++) {
          final index = offset + i;
          final id = page[i].id;
          if (index == current) {
            // Never remove the row that is currently playing.
            seen.add(id);
            continue;
          }
          if (!seen.add(id)) duplicates.add(index);
        }
        offset += page.length;
        progress.value = math.min(offset, length);
        if (page.length < 500) break;
      }
    } catch (e) {
      if (navigator.mounted && navigator.canPop()) navigator.pop();
      progress.dispose();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.pick('检查队列失败：$e', 'Failed to check queue: $e'),
              ),
            ),
          );
      }
      return;
    }
    if (navigator.mounted && navigator.canPop()) navigator.pop();
    progress.dispose();
    if (!context.mounted) return;

    if (duplicates.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick('队列里没有重复曲目', 'No duplicate queue tracks'),
            ),
          ),
        );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.pick('移除重复曲目？', 'Remove duplicate tracks?')),
        content: Text(
          context.l10n.pick(
            '将移除 ${duplicates.length} 个重复条目，每个曲目保留第一次出现；正在播放的曲目不会移除。',
            'This removes ${duplicates.length} duplicate entries, keeping the first occurrence of each track; the currently playing track is never removed.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(context.l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(context.l10n.pick('移除', 'Remove')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    duplicates.sort((a, b) => b.compareTo(a));
    var removed = 0;
    var failed = 0;
    for (final index in duplicates) {
      try {
        core.queueRemove(index: index);
        removed++;
      } catch (_) {
        failed++;
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              failed == 0
                  ? context.l10n.pick(
                      '已移除 $removed 个重复条目',
                      'Removed $removed duplicate entries',
                    )
                  : context.l10n.pick(
                      '已移除 $removed 个，$failed 个失败',
                      'Removed $removed; $failed failed',
                    ),
            ),
          ),
        );
    }
  }

  Future<void> _showQueueInfo(BuildContext context) async {
    final playback = ref.read(playbackProvider);
    if (playback.queueLength == 0) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _QueueInfoSheet(
        length: playback.queueLength,
        currentIndex: playback.queueIndex,
      ),
    );
  }

  Future<void> _showRowMenu(
    BuildContext context,
    TrackRowDto row,
    int index,
    VoidCallback? moveToNext,
  ) async {
    final length = ref.read(playbackProvider).queueLength;
    final loved = ref.read(lovedOverridesProvider)[row.id] ?? row.loved;
    final downloadState = ref.read(downloadStateProvider(row.id));
    final messenger = ScaffoldMessenger.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        final l10n = sheet.l10n;
        final errorColor = Theme.of(sheet).colorScheme.error;
        void close() => Navigator.of(sheet).pop();
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (moveToNext != null)
                  ListTile(
                    leading: const Icon(Icons.queue_play_next_rounded),
                    title: Text(moveToNextLabel(sheet)),
                    onTap: () {
                      close();
                      moveToNext();
                    },
                  ),
                if (row.albumTitle != null && row.albumTitle!.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.album_outlined),
                    title: Text(l10n.pick('查看专辑', 'View Album')),
                    onTap: () {
                      close();
                      unawaited(_openAlbum(context, row, messenger));
                    },
                  ),
                if (row.artistLine.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.person_outline_rounded),
                    title: Text(l10n.pick('查看艺人', 'View Artist')),
                    onTap: () {
                      close();
                      unawaited(_openArtist(context, row, messenger));
                    },
                  ),
                ListTile(
                  leading: Icon(
                    loved
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                  ),
                  title: Text(
                    loved
                        ? l10n.pick('取消喜欢', 'Unlike')
                        : l10n.pick('喜欢', 'Like'),
                  ),
                  onTap: () async {
                    close();
                    final ok = await ref
                        .read(libraryActionsProvider)
                        .setLoved(row.id, !loved);
                    if (!ok) {
                      messenger
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          SnackBar(
                            content: Text(
                              l10n.pick(
                                '更新收藏失败，请稍后再试',
                                'Failed to update favorite, please try again later',
                              ),
                            ),
                          ),
                        );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add_rounded),
                  title: Text(l10n.pick('添加到歌单', 'Add to Playlist')),
                  onTap: () {
                    close();
                    unawaited(
                      showAddToPlaylistSheet(
                        context,
                        trackId: row.id,
                        trackTitle: row.title,
                      ),
                    );
                  },
                ),
                if (!row.isLocal || downloadState != null)
                  ListTile(
                    leading: Icon(switch (downloadState) {
                      null => Icons.download_for_offline_outlined,
                      OfflineStateDto.ready => Icons.delete_outline_rounded,
                      OfflineStateDto.failed => Icons.refresh_rounded,
                      OfflineStateDto.downloading => Icons.close_rounded,
                      OfflineStateDto.queued => Icons.download_rounded,
                    }),
                    title: Text(downloadMenuLabel(downloadState)),
                    onTap: () {
                      close();
                      unawaited(
                        runDownloadMenuAction(
                          context,
                          ref,
                          row.id,
                          downloadState,
                        ),
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.keyboard_arrow_up_rounded),
                  title: Text(l10n.pick('上移', 'Move up')),
                  enabled: index > 0,
                  onTap: index > 0
                      ? () {
                          close();
                          ref
                              .read(playerActionsProvider)
                              .moveQueueItem(index, index - 1);
                        }
                      : null,
                ),
                ListTile(
                  leading: const Icon(Icons.keyboard_arrow_down_rounded),
                  title: Text(l10n.pick('下移', 'Move down')),
                  enabled: index + 1 < length,
                  onTap: index + 1 < length
                      ? () {
                          close();
                          ref
                              .read(playerActionsProvider)
                              .moveQueueItem(index, index + 1);
                        }
                      : null,
                ),
                ListTile(
                  leading: const Icon(Icons.vertical_align_top_rounded),
                  title: Text(l10n.pick('移到顶部', 'Move to top')),
                  enabled: index > 0,
                  onTap: index > 0
                      ? () {
                          close();
                          ref
                              .read(playerActionsProvider)
                              .moveQueueItem(index, 0);
                        }
                      : null,
                ),
                ListTile(
                  leading: const Icon(Icons.vertical_align_bottom_rounded),
                  title: Text(l10n.pick('移到底部', 'Move to bottom')),
                  enabled: index + 1 < length,
                  onTap: index + 1 < length
                      ? () {
                          close();
                          ref
                              .read(playerActionsProvider)
                              .moveQueueItem(index, length - 1);
                        }
                      : null,
                ),
                ListTile(
                  leading: Icon(Icons.close_rounded, color: errorColor),
                  title: Text(
                    l10n.pick('从队列移除', 'Remove from Queue'),
                    style: TextStyle(color: errorColor),
                  ),
                  onTap: () {
                    close();
                    _remove(index);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openAlbum(
    BuildContext context,
    TrackRowDto row,
    ScaffoldMessengerState messenger,
  ) async {
    final l10n = context.l10n;
    try {
      final track = await core.getTrack(trackId: row.id);
      final albumId = track.albumId;
      if (albumId == null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(l10n.pick('这首歌没有关联专辑', 'This track has no album')),
            ),
          );
        return;
      }
      if (!context.mounted) return;
      await Navigator.of(context).push(AlbumDetailPage.route(albumId.toInt()));
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.pick('打开专辑失败：$e', 'Failed to open album: $e')),
          ),
        );
    }
  }

  Future<void> _openArtist(
    BuildContext context,
    TrackRowDto row,
    ScaffoldMessengerState messenger,
  ) async {
    final l10n = context.l10n;
    try {
      final name = row.artistLine.split(' / ').first.trim();
      final id = await ref.read(artistIdForNameProvider(name).future);
      if (id == null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                l10n.pick('资料库里没有这位艺人', 'Artist not found in library'),
              ),
            ),
          );
        return;
      }
      if (!context.mounted) return;
      await Navigator.of(context).push(ArtistDetailPage.route(id));
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.pick('打开艺人失败：$e', 'Failed to open artist: $e')),
          ),
        );
    }
  }

  Future<void> _confirmClear(BuildContext context) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.pick('清空播放队列？', 'Clear the queue?')),
        content: Text(
          l10n.pick(
            '队列和当前播放都会停止。',
            'The queue and current playback will stop.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.pick('清空', 'Clear')),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      ref.read(playerActionsProvider).clearQueue();
    }
  }

  Future<void> _saveQueueAsPlaylist(BuildContext context) async {
    final length = ref.read(playbackProvider).queueLength;
    if (length == 0) return;
    final l10n = context.l10n;
    final controller = TextEditingController(
      text:
          '${l10n.pick('播放队列', 'Queue')} '
          '${DateTime.now().toString().substring(0, 16).replaceAll('T', ' ')}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.pick('保存为歌单', 'Save as Playlist')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.pick('歌单名称', 'Playlist name'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(controller.text.trim()),
            child: Text(l10n.pick('保存', 'Save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !context.mounted) return;
    if (!mounted) return;
    final progress = ValueNotifier<int>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => nonDismissibleProgressDialog(
          title: Text(l10n.pick('正在保存歌单', 'Saving Playlist')),
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: (done / length).clamp(0.0, 1.0)),
                const SizedBox(height: LekisSpacing.md),
                Text('$done / $length'),
              ],
            ),
          ),
        ),
      ),
    );
    var saved = 0;
    var failed = 0;
    try {
      final playlistId = await core.createPlaylist(name: name);
      var offset = 0;
      while (offset < length) {
        final rows = await core.queueItems(offset: offset, limit: 200);
        if (rows.isEmpty) break;
        for (final row in rows) {
          try {
            final track = await core.getTrack(trackId: row.id);
            await core.addToPlaylist(
              playlistId: playlistId,
              trackUid: track.uid,
            );
            saved++;
          } catch (_) {
            failed++;
          }
          progress.value = (progress.value + 1).clamp(0, length);
        }
        offset += rows.length;
      }
      if (saved == 0) {
        try {
          await core.deletePlaylist(playlistId: playlistId);
        } catch (_) {
          // Best-effort cleanup; the error below is the useful one.
        }
      }
      if (context.mounted) {
        ref.invalidate(playlistsProvider);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                saved == 0
                    ? l10n.pick('没有可保存的曲目', 'No tracks could be saved')
                    : failed == 0
                    ? l10n.pick(
                        '已保存 $saved 首到歌单「$name」',
                        'Saved $saved tracks to "$name"',
                      )
                    : l10n.pick(
                        '已保存 $saved 首到歌单「$name」，$failed 首失败',
                        'Saved $saved tracks to "$name"; $failed failed',
                      ),
              ),
            ),
          );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                l10n.pick('保存歌单失败：$e', 'Failed to save playlist: $e'),
              ),
            ),
          );
      }
    } finally {
      if (navigator.mounted && navigator.canPop()) navigator.pop();
      progress.dispose();
    }
  }

  Future<void> _copyQueue(BuildContext context) async {
    final length = ref.read(playbackProvider).queueLength;
    if (length == 0) return;
    final l10n = context.l10n;
    final limit = math.min(length, 500);
    try {
      final rows = await core.queueItems(offset: 0, limit: limit);
      final text = [
        for (var i = 0; i < rows.length; i++)
          '${i + 1}. ${rows[i].title}'
              '${rows[i].artistLine.isEmpty ? '' : ' — ${rows[i].artistLine}'}',
      ].join('\n');
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              length > limit
                  ? l10n.pick(
                      '已复制前 $limit 首（共 $length 首）',
                      'Copied first $limit of $length tracks',
                    )
                  : l10n.pick(
                      '已复制队列（$length 首）',
                      'Copied $length queue tracks',
                    ),
            ),
          ),
        );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.pick('复制队列失败：$e', 'Failed to copy queue: $e')),
          ),
        );
    }
  }

  void _remove(int index) {
    if (_removing.contains(index)) return;
    final version = ref.read(playbackProvider).queueVersion;
    setState(() => _removing.add(index));
    _removeDelay?.cancel();
    _removeDelay = Timer(LekisMotion.fast, () {
      if (!mounted) return;
      if (ref.read(playbackProvider).queueVersion != version) return;
      ref.read(playerActionsProvider).removeQueueAt(index);
      // If the core rejects the change, do not leave an invisible row.
      _removeFallback?.cancel();
      _removeFallback = Timer(LekisMotion.slow, () {
        if (!mounted) return;
        if (_removing.contains(index) &&
            ref.read(playbackProvider).queueVersion == version) {
          setState(() => _removing.remove(index));
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(playbackProvider.select((s) => s.queueVersion), (
      previous,
      next,
    ) {
      // The faded-out rows stay hidden until the rebuilt list is shown
      // ([_present]); only the pending timers are stale now.
      if (previous != null && previous != next && mounted) {
        _removeDelay?.cancel();
        _removeFallback?.cancel();
      }
    });

    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final queueLength = ref.watch(
      playbackProvider.select((s) => s.queueLength),
    );
    final currentIndex = ref.watch(
      playbackProvider.select((s) => s.queueIndex),
    );
    final latest = ref.watch(queueListProvider);
    // Over artwork the page behind is already blurred: the panel is the
    // theme's translucent glass fill with its rim, not an opaque sheet.
    final surface = context.lekisSurface;
    final panelColor = surface.onMedia
        ? surface.panel
        : Color.alphaBlend(
            colors.surfaceElevated.withValues(alpha: 0.92),
            theme.colorScheme.surface,
          );
    final rim = surface.onMedia ? surface.panelBorder : colors.outline;
    // Embedded panes only need the seam to the content on their left; the
    // modal side panel separates from the artwork on every edge it has.
    final Border? border;
    if (widget.embedded) {
      border = Border(left: BorderSide(color: rim));
    } else if (surface.onMedia) {
      border = Border.fromBorderSide(BorderSide(color: rim));
    } else {
      border = null;
    }

    return Material(
      key: const ValueKey('queue-panel'),
      color: panelColor,
      child: DecoratedBox(
        decoration: BoxDecoration(border: border),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeader) ...[
              _QueueHeader(
                length: queueLength,
                onCopy: queueLength == 0 ? null : () => _copyQueue(context),
                onSaveAsPlaylist: queueLength == 0
                    ? null
                    : () => _saveQueueAsPlaylist(context),
                onClear: queueLength == 0 ? null : () => _confirmClear(context),
                onShuffleUpcoming:
                    currentIndex == null || currentIndex + 2 >= queueLength
                    ? null
                    : () => _shuffleUpcoming(context),
                onClearUpcoming:
                    currentIndex == null || currentIndex + 1 >= queueLength
                    ? null
                    : () => _clearUpcoming(context),
                onDedupe: queueLength < 2 ? null : () => _dedupeQueue(context),
                onInfo: queueLength == 0 ? null : () => _showQueueInfo(context),
                onFind: queueLength == 0 ? null : () => _findInQueue(context),
                onJumpToCurrent: currentIndex == null
                    ? null
                    : () => _jumpToCurrent(currentIndex),
                onClose: widget.onClose,
              ),
              Divider(height: 1, color: colors.outline),
            ],
            Expanded(
              child: ListenableBuilder(
                listenable: latest,
                builder: (context, _) {
                  final list = _present(latest);
                  if (queueLength == 0) {
                    return _QueueEmpty(
                      message: context.l10n.pick('队列为空', 'Queue is empty'),
                      colors: colors,
                      theme: theme,
                    );
                  }
                  if (list.error != null && list.itemCount == 0) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            context.l10n.pick('队列加载失败', 'Failed to load queue'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: LekisSpacing.sm),
                          TextButton(
                            onPressed: list.retry,
                            child: Text(context.l10n.pick('重试', 'Retry')),
                          ),
                        ],
                      ),
                    );
                  }
                  if (list.isInitialLoading) {
                    return const Center(
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }

                  final rowCount = list.itemCount;
                  _scheduleJump(currentIndex, rowCount);

                  return Scrollbar(
                    controller: _scroll,
                    interactive: true,
                    child: ListView.builder(
                      key: const ValueKey('queue-panel.list'),
                      controller: _scroll,
                      itemExtent: QueuePanel.rowExtent,
                      itemCount: rowCount,
                      itemBuilder: (context, index) {
                        final row = list.itemAt(index);
                        if (row == null) {
                          return _QueueRowPlaceholder(colors: colors);
                        }
                        final removing = _removing.contains(index);
                        final moveToNext = identical(list, latest) && !removing
                            ? queueMoveToNext(ref, index)
                            : null;
                        return ListMotionRow(
                          key: ValueKey('queue-panel.entry-$index-${row.id}'),
                          motion: _motion,
                          index: index,
                          child: AnimatedSlide(
                            offset: removing
                                ? const Offset(0.15, 0)
                                : Offset.zero,
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : LekisMotion.fast,
                            child: AnimatedOpacity(
                              opacity: removing ? 0 : 1,
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : LekisMotion.fast,
                              child: _QueueRow(
                                key: ValueKey('queue-panel.row-$index'),
                                row: row,
                                current: index == currentIndex,
                                onPlay: () => ref
                                    .read(playerActionsProvider)
                                    .playQueueAt(index),
                                onLongPress: () => _showRowMenu(
                                  context,
                                  row,
                                  index,
                                  moveToNext,
                                ),
                                onRemove: () => _remove(index),
                                onMoveUp: index > 0
                                    ? () => ref
                                          .read(playerActionsProvider)
                                          .moveQueueItem(index, index - 1)
                                    : null,
                                onMoveDown: index + 1 < rowCount
                                    ? () => ref
                                          .read(playerActionsProvider)
                                          .moveQueueItem(index, index + 1)
                                    : null,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueInfoSheet extends StatefulWidget {
  const _QueueInfoSheet({required this.length, required this.currentIndex});

  final int length;
  final int? currentIndex;

  @override
  State<_QueueInfoSheet> createState() => _QueueInfoSheetState();
}

class _QueueInfo {
  const _QueueInfo({
    required this.total,
    required this.totalMs,
    required this.upcoming,
    required this.upcomingMs,
  });

  final int total;
  final int totalMs;
  final int upcoming;
  final int upcomingMs;
}

class _QueueInfoSheetState extends State<_QueueInfoSheet> {
  late Future<_QueueInfo> _future = _load();

  Future<_QueueInfo> _load() async {
    var total = 0;
    var totalMs = 0;
    var upcoming = 0;
    var upcomingMs = 0;
    final current = widget.currentIndex;
    var offset = 0;
    while (offset < widget.length) {
      final page = await core.queueItems(
        offset: offset,
        limit: math.min(500, widget.length - offset),
      );
      if (page.isEmpty) break;
      for (var i = 0; i < page.length; i++) {
        final index = offset + i;
        final ms = page[i].durationMs.toInt();
        total++;
        totalMs += ms;
        if (current != null && index > current) {
          upcoming++;
          upcomingMs += ms;
        }
      }
      offset += page.length;
      if (page.length < 500) break;
    }
    return _QueueInfo(
      total: total,
      totalMs: totalMs,
      upcoming: upcoming,
      upcomingMs: upcomingMs,
    );
  }

  void _retry() {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          LekisSpacing.xl,
          0,
          LekisSpacing.xl,
          LekisSpacing.xl,
        ),
        child: FutureBuilder<_QueueInfo>(
          future: _future,
          builder: (context, snapshot) {
            final info = snapshot.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.l10n.pick('队列信息', 'Queue Info'),
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: LekisSpacing.md),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: LekisSpacing.xl),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (snapshot.hasError)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        context.l10n.pick(
                          '读取队列失败：${snapshot.error}',
                          'Failed to read queue: ${snapshot.error}',
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: LekisSpacing.sm),
                      TextButton(
                        onPressed: _retry,
                        child: Text(context.l10n.pick('重试', 'Retry')),
                      ),
                    ],
                  )
                else if (info != null) ...[
                  _QueueInfoRow(
                    icon: Icons.queue_music_rounded,
                    label: context.l10n.pick('总曲目', 'Total Tracks'),
                    value: context.l10n.pick(
                      '${info.total} 首',
                      '${info.total} tracks',
                    ),
                  ),
                  _QueueInfoRow(
                    icon: Icons.timer_outlined,
                    label: context.l10n.pick('总时长', 'Total Time'),
                    value: formatTotalDuration(
                      Duration(milliseconds: info.totalMs),
                    ),
                  ),
                  if (widget.currentIndex != null) ...[
                    const Divider(height: 1),
                    _QueueInfoRow(
                      icon: Icons.playlist_play_rounded,
                      label: context.l10n.pick('当前之后', 'After Current'),
                      value: context.l10n.pick(
                        '${info.upcoming} 首 · '
                            '${formatTotalDuration(Duration(milliseconds: info.upcomingMs))}',
                        '${info.upcoming} tracks · '
                            '${formatTotalDuration(Duration(milliseconds: info.upcomingMs))}',
                      ),
                    ),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _QueueInfoRow extends StatelessWidget {
  const _QueueInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: LekisSpacing.md),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

enum _QueueHeaderAction {
  info,
  find,
  copy,
  saveAsPlaylist,
  shuffleUpcoming,
  clearUpcoming,
  dedupe,
  clear,
}

class _QueueHeader extends StatelessWidget {
  const _QueueHeader({
    required this.length,
    this.onCopy,
    this.onSaveAsPlaylist,
    this.onClear,
    this.onClearUpcoming,
    this.onShuffleUpcoming,
    this.onDedupe,
    this.onInfo,
    this.onFind,
    this.onJumpToCurrent,
    this.onClose,
  });

  final int length;
  final VoidCallback? onCopy;
  final VoidCallback? onSaveAsPlaylist;
  final VoidCallback? onClear;
  final VoidCallback? onClearUpcoming;
  final VoidCallback? onShuffleUpcoming;
  final VoidCallback? onDedupe;
  final VoidCallback? onInfo;
  final VoidCallback? onFind;
  final VoidCallback? onJumpToCurrent;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        LekisSpacing.lg,
        0,
        onClose == null ? LekisSpacing.lg : LekisSpacing.sm,
        LekisSpacing.xs,
      ),
      child: SizedBox(
        height: LekisSizes.touchTargetMin,
        child: Row(
          children: [
            Icon(
              Icons.queue_music_rounded,
              size: LekisSpacing.xl,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: LekisSpacing.sm),
            Text(context.l10n.queue, style: theme.textTheme.titleMedium),
            const SizedBox(width: LekisSpacing.sm),
            _CountBadge(count: length),
            const Spacer(),
            if (onInfo != null ||
                onFind != null ||
                onCopy != null ||
                onSaveAsPlaylist != null ||
                onShuffleUpcoming != null ||
                onClearUpcoming != null ||
                onDedupe != null ||
                onClear != null)
              PopupMenuButton<_QueueHeaderAction>(
                key: const ValueKey('queue-panel.more'),
                tooltip: context.l10n.pick('队列操作', 'Queue actions'),
                icon: const Icon(Icons.more_horiz_rounded, size: 20),
                onSelected: (action) {
                  switch (action) {
                    case _QueueHeaderAction.info:
                      onInfo?.call();
                    case _QueueHeaderAction.find:
                      onFind?.call();
                    case _QueueHeaderAction.copy:
                      onCopy?.call();
                    case _QueueHeaderAction.saveAsPlaylist:
                      onSaveAsPlaylist?.call();
                    case _QueueHeaderAction.shuffleUpcoming:
                      onShuffleUpcoming?.call();
                    case _QueueHeaderAction.clearUpcoming:
                      onClearUpcoming?.call();
                    case _QueueHeaderAction.dedupe:
                      onDedupe?.call();
                    case _QueueHeaderAction.clear:
                      onClear?.call();
                  }
                },
                itemBuilder: (_) => [
                  if (onInfo != null)
                    PopupMenuItem(
                      value: _QueueHeaderAction.info,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.info_outline_rounded),
                        title: Text(context.l10n.pick('队列信息', 'Queue Info')),
                      ),
                    ),
                  if (onFind != null)
                    PopupMenuItem(
                      value: _QueueHeaderAction.find,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.search_rounded),
                        title: Text(
                          context.l10n.pick('在队列中查找', 'Find in Queue'),
                        ),
                      ),
                    ),
                  if (onCopy != null)
                    PopupMenuItem(
                      value: _QueueHeaderAction.copy,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.content_copy_rounded),
                        title: Text(context.l10n.pick('复制队列', 'Copy Queue')),
                      ),
                    ),
                  if (onSaveAsPlaylist != null)
                    PopupMenuItem(
                      value: _QueueHeaderAction.saveAsPlaylist,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.playlist_add_rounded),
                        title: Text(
                          context.l10n.pick('保存为歌单', 'Save as Playlist'),
                        ),
                      ),
                    ),
                  if (onShuffleUpcoming != null)
                    PopupMenuItem(
                      value: _QueueHeaderAction.shuffleUpcoming,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.shuffle_rounded),
                        title: Text(
                          context.l10n.pick('打乱未播放曲目', 'Shuffle Upcoming'),
                        ),
                      ),
                    ),
                  if (onClearUpcoming != null)
                    PopupMenuItem(
                      value: _QueueHeaderAction.clearUpcoming,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.playlist_remove_rounded),
                        title: Text(
                          context.l10n.pick('清除未播放曲目', 'Clear Upcoming'),
                        ),
                      ),
                    ),
                  if (onDedupe != null)
                    PopupMenuItem(
                      value: _QueueHeaderAction.dedupe,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.filter_alt_off_rounded),
                        title: Text(
                          context.l10n.pick('移除重复曲目', 'Remove Duplicates'),
                        ),
                      ),
                    ),
                  if (onClear != null)
                    PopupMenuItem(
                      value: _QueueHeaderAction.clear,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.delete_sweep_outlined),
                        title: Text(context.l10n.pick('清空队列', 'Clear Queue')),
                      ),
                    ),
                ],
              ),
            if (onJumpToCurrent != null)
              IconButton(
                key: const ValueKey('queue-panel.jump-current'),
                tooltip: context.l10n.pick('定位到正在播放', 'Jump to Now Playing'),
                constraints: const BoxConstraints(
                  minWidth: LekisSizes.touchTargetMin,
                  minHeight: LekisSizes.touchTargetMin,
                ),
                onPressed: onJumpToCurrent,
                icon: const Icon(Icons.my_location_rounded, size: 20),
              ),
            if (onClose != null)
              IconButton(
                tooltip: context.l10n.hideQueue,
                constraints: const BoxConstraints(
                  minWidth: LekisSizes.touchTargetMin,
                  minHeight: LekisSizes.touchTargetMin,
                ),
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    // Material's badge follows the theme (accent pill, tabular label), so the
    // header count matches the queue toggle on the artwork.
    return Badge(
      key: const ValueKey('queue-panel.count'),
      label: Text('$count'),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.row,
    required this.current,
    required this.onPlay,
    required this.onLongPress,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final TrackRowDto row;
  final bool current;
  final VoidCallback onPlay;
  final VoidCallback onLongPress;
  final VoidCallback onRemove;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Semantics(
      button: true,
      selected: current,
      label:
          '${row.title.isEmpty ? context.l10n.pick('已删除的曲目', 'Deleted track') : row.title}'
          '${row.artistLine.isEmpty ? '' : ', ${row.artistLine}'}',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPlay,
          onLongPress: onLongPress,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : LekisMotion.fast,
            margin: const EdgeInsets.symmetric(
              horizontal: LekisSpacing.sm,
              vertical: LekisSpacing.xxs,
            ),
            padding: const EdgeInsets.only(
              left: LekisSpacing.sm,
              right: LekisSpacing.xxs,
            ),
            decoration: BoxDecoration(
              color: current ? colors.accentSoft : null,
              borderRadius: BorderRadius.circular(LekisRadius.sm),
            ),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: LekisSizes.listArtwork - LekisSpacing.md,
                  child: TrackArtwork(
                    trackId: row.id,
                    hasArtwork: row.artworkId != null || !row.isLocal,
                    radius: LekisRadius.artworkList,
                    placeholderLabel: row.title,
                  ),
                ),
                const SizedBox(width: LekisSpacing.sm),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.title.isEmpty
                            ? context.l10n.pick('（已删除）', '(Deleted)')
                            : row.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: current ? colors.accent : null,
                          fontWeight: current ? FontWeight.w600 : null,
                        ),
                      ),
                      Text(
                        row.artistLine.isEmpty ? '—' : row.artistLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (current)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LekisSpacing.xxs,
                    ),
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      size: 18,
                      color: colors.accent,
                    ),
                  ),
                _QueueAction(
                  icon: Icons.keyboard_arrow_up_rounded,
                  tooltip: context.l10n.pick('上移', 'Move up'),
                  onPressed: onMoveUp,
                ),
                _QueueAction(
                  icon: Icons.keyboard_arrow_down_rounded,
                  tooltip: context.l10n.pick('下移', 'Move down'),
                  onPressed: onMoveDown,
                ),
                _QueueAction(
                  icon: Icons.close_rounded,
                  tooltip: context.l10n.pick('从队列移除', 'Remove from Queue'),
                  onPressed: onRemove,
                  destructive: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueAction extends StatelessWidget {
  const _QueueAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 16,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(
        minWidth: LekisSpacing.xxl,
        minHeight: LekisSpacing.xxl,
      ),
      color: destructive ? colors.danger : colors.onSurfaceVariant,
      disabledColor: colors.outline,
      icon: Icon(icon),
    );
  }
}

class _QueueRowPlaceholder extends StatelessWidget {
  const _QueueRowPlaceholder({required this.colors});

  final LekisColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.md,
        vertical: LekisSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: LekisSizes.listArtwork - LekisSpacing.md,
            height: LekisSizes.listArtwork - LekisSpacing.md,
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(LekisRadius.artworkList),
            ),
          ),
          const SizedBox(width: LekisSpacing.sm),
          Expanded(
            child: Container(
              height: LekisSpacing.md,
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(LekisRadius.pill),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueEmpty extends StatelessWidget {
  const _QueueEmpty({
    required this.message,
    required this.colors,
    required this.theme,
  });

  final String message;
  final LekisColors colors;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.queue_music_rounded,
            size: LekisSpacing.xxl,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Slide-in right-hand queue for wide windows (player bar, long press, ...).
Future<void> showQueueSidePanel(BuildContext context) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  // `showGeneralDialog` does not capture inherited themes, so the panel would
  // fall back to the app's opaque palette over the Now Playing artwork. Keep
  // the caller's theme (on-media glass over artwork) around the page.
  final theme = Theme.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.l10n.pick('关闭播放队列', 'Close queue'),
    barrierColor: context.lekisColors.scrim,
    transitionDuration: reduceMotion ? Duration.zero : LekisMotion.normal,
    pageBuilder: (context, _, _) => Theme(
      data: theme,
      child: Align(
        alignment: Alignment.centerRight,
        child: SafeArea(
          left: false,
          child: SizedBox(
            width: QueuePanel.width,
            height: double.infinity,
            child: QueuePanel(
              embedded: false,
              onClose: () => Navigator.of(context).maybePop(),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.12, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// True on expanded / wide windows and on desktop (which has no bottom
/// sheets), where the queue is a side panel.
bool usesQueueSidePanel(BuildContext context) =>
    !UiProfile.current.prefersSheets ||
    context.widthClass >= WindowWidthClass.expanded;
