// Desktop playback queue: a 320 dp right-hand panel with the whole queue.
//
// It replaces the compact bottom sheet on expanded / wide windows and is also
// embedded as the third Now Playing pane (cover | controls | queue).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/library_providers.dart'
    show PagedList, artistIdForNameProvider;
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/layout/window_size.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/nav_icon.dart' show lekisReduceMotion;
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/list_motion.dart';
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

  Future<void> _showRowMenu(
    BuildContext context,
    TrackRowDto row,
    int index,
  ) async {
    final length = ref.read(playbackProvider).queueLength;
    final loved = ref.read(lovedOverridesProvider)[row.id] ?? row.loved;
    final messenger = ScaffoldMessenger.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        final l10n = sheet.l10n;
        final errorColor = Theme.of(sheet).colorScheme.error;
        void close() => Navigator.of(sheet).pop();
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                  loved ? l10n.pick('取消喜欢', 'Unlike') : l10n.pick('喜欢', 'Like'),
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
                                onLongPress: () =>
                                    _showRowMenu(context, row, index),
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

class _QueueHeader extends StatelessWidget {
  const _QueueHeader({
    required this.length,
    this.onJumpToCurrent,
    this.onClose,
  });

  final int length;
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
