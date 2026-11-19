// Desktop playback queue: a 320 dp right-hand panel with the whole queue.
//
// It replaces the compact bottom sheet on expanded / wide windows and is also
// embedded as the third Now Playing pane (cover | controls | queue).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/layout/window_size.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
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

class _QueuePanelState extends ConsumerState<QueuePanel> {
  final _scroll = ScrollController();
  final Set<int> _removing = <int>{};
  Timer? _removeDelay;
  Timer? _removeFallback;
  bool _jumpedToCurrent = false;

  @override
  void dispose() {
    _removeDelay?.cancel();
    _removeFallback?.cancel();
    _scroll.dispose();
    super.dispose();
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
      if (previous != null && previous != next && mounted) {
        _removeDelay?.cancel();
        _removeFallback?.cancel();
        setState(_removing.clear);
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
    final list = ref.watch(queueListProvider);
    final panelColor = Color.alphaBlend(
      colors.surfaceElevated.withValues(alpha: 0.92),
      theme.colorScheme.surface,
    );

    return Material(
      key: const ValueKey('queue-panel'),
      color: panelColor,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: widget.embedded
              ? Border(left: BorderSide(color: colors.outline))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeader) ...[
              _QueueHeader(length: queueLength, onClose: widget.onClose),
              Divider(height: 1, color: colors.outline),
            ],
            Expanded(
              child: ListenableBuilder(
                listenable: list,
                builder: (context, _) {
                  if (queueLength == 0) {
                    return _QueueEmpty(
                      message: '队列为空',
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
                            '队列加载失败',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: LekisSpacing.sm),
                          TextButton(
                            onPressed: list.retry,
                            child: const Text('重试'),
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
                        return _QueueRowEntrance(
                          key: ValueKey('queue-panel.entry-$index-${row.id}'),
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : LekisMotion.normal,
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
  const _QueueHeader({required this.length, this.onClose});

  final int length;
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
            Text('播放队列', style: theme.textTheme.titleMedium),
            const SizedBox(width: LekisSpacing.sm),
            _CountBadge(count: length),
            const Spacer(),
            if (onClose != null)
              IconButton(
                tooltip: '关闭播放队列',
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
    final colors = context.lekisColors;
    return Container(
      key: const ValueKey('queue-panel.count'),
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.sm,
        vertical: LekisSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(LekisRadius.pill),
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.accent,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.row,
    required this.current,
    required this.onPlay,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final TrackRowDto row;
  final bool current;
  final VoidCallback onPlay;
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
          '${row.title.isEmpty ? '已删除的曲目' : row.title}'
          '${row.artistLine.isEmpty ? '' : ', ${row.artistLine}'}',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPlay,
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
                    hasArtwork: row.artworkId != null,
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
                        row.title.isEmpty ? '（已删除）' : row.title,
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
                  tooltip: '上移',
                  onPressed: onMoveUp,
                ),
                _QueueAction(
                  icon: Icons.keyboard_arrow_down_rounded,
                  tooltip: '下移',
                  onPressed: onMoveDown,
                ),
                _QueueAction(
                  icon: Icons.close_rounded,
                  tooltip: '从队列移除',
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

/// Soft fade / slide for rows that appear while the panel is open.
class _QueueRowEntrance extends StatelessWidget {
  const _QueueRowEntrance({
    super.key,
    required this.duration,
    required this.child,
  });

  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (duration == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(LekisSpacing.sm * (1 - t), 0),
          child: child,
        ),
      ),
      child: child,
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
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭播放队列',
    barrierColor: context.lekisColors.scrim,
    transitionDuration: reduceMotion ? Duration.zero : LekisMotion.normal,
    pageBuilder: (context, _, _) => Align(
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

/// True on expanded / wide windows, where the queue is a side panel.
bool usesQueueSidePanel(BuildContext context) =>
    context.widthClass >= WindowWidthClass.expanded;
