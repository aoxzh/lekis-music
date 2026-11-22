// Compact queue preview used by the mobile bottom sheet. Wide windows use
// the full, paged QueuePanel instead.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_panel.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/nav_icon.dart' show lekisReduceMotion;
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:lekis/src/widgets/list_motion.dart';
import 'package:material_ui/material_ui.dart';

class QueueList extends ConsumerStatefulWidget {
  const QueueList({super.key, this.compact = false});

  /// Dense rows for the 320 dp context panel.
  final bool compact;

  @override
  ConsumerState<QueueList> createState() => _QueueListState();
}

class _QueueListState extends ConsumerState<QueueList>
    with SingleTickerProviderStateMixin {
  late final ListMotion _motion = ListMotion(vsync: this);

  /// Last provider data diffed against, and the order on screen (which a
  /// drag may have changed ahead of the core's reply).
  List<TrackRowDto>? _source;
  List<TrackRowDto>? _optimistic;
  List<Object> _shownKeys = const [];

  /// Rows collapsing out (by key) until the queue reports the removal.
  final Set<Object> _removing = <Object>{};
  Timer? _settleFallback;

  @override
  void dispose() {
    _settleFallback?.cancel();
    _motion.dispose();
    super.dispose();
  }

  static List<Object> _keysOf(List<TrackRowDto> rows) =>
      occurrenceKeys(rows, (row) => row.id);

  /// Fresh provider data: animate from what is on screen to it.
  List<TrackRowDto> _present(List<TrackRowDto> items) {
    if (!identical(items, _source)) {
      final keys = _keysOf(items);
      // Collapsed rows already left the screen; diff without them.
      final old = [
        for (final k in _shownKeys)
          if (!_removing.contains(k)) k,
      ];
      _motion.listChanged(
        old: (i) => old[i],
        oldLength: old.length,
        now: (i) => keys[i],
        nowLength: keys.length,
        animate: _source != null && !lekisReduceMotion(context),
      );
      _source = items;
      _optimistic = null;
      _removing.clear();
      _settleFallback?.cancel();
      _shownKeys = keys;
    }
    return _optimistic ?? items;
  }

  /// If the core does not answer an edit, put the rows back as they were.
  void _armFallback() {
    _settleFallback?.cancel();
    _settleFallback = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      final source = _source;
      setState(() {
        if (_optimistic != null && source != null) {
          final from = _shownKeys;
          final keys = _keysOf(source);
          _motion.listChanged(
            old: (i) => from[i],
            oldLength: from.length,
            now: (i) => keys[i],
            nowLength: keys.length,
            animate: !lekisReduceMotion(context),
          );
          _shownKeys = keys;
        }
        _optimistic = null;
        _removing.clear();
      });
    });
  }

  void _reorder(List<TrackRowDto> shown, int start, int from, int to) {
    if (from == to) return;
    // onReorderItem's [to] already accounts for the row leaving [from].
    final moved = List.of(shown);
    moved.insert(to, moved.removeAt(from));
    setState(() {
      _optimistic = moved;
      _shownKeys = _keysOf(moved);
      // The dragged row was dropped in place by the list itself.
      _motion.settle();
    });
    _armFallback();
    ref.read(playerActionsProvider).moveQueueItem(start + from, start + to);
  }

  void _remove(Object key, int actualIndex) {
    if (_removing.contains(key)) return;
    final version = ref.read(playbackProvider).queueVersion;
    setState(() => _removing.add(key));
    void commit() {
      if (!mounted) return;
      if (ref.read(playbackProvider).queueVersion != version) return;
      ref.read(playerActionsProvider).removeQueueAt(actualIndex);
      _armFallback();
    }

    if (lekisReduceMotion(context)) {
      commit();
    } else {
      Timer(ListRowCollapse.duration, commit);
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    final rows = ref.watch(queuePreviewProvider);
    final playback = ref.watch(
      playbackProvider.select(
        (s) => (
          trackId: s.trackId,
          queueIndex: s.queueIndex,
          queueLength: s.queueLength,
        ),
      ),
    );
    final start = queuePreviewStart(playback.queueLength, playback.queueIndex);
    final actions = ref.read(playerActionsProvider);
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    // Phone-width sheets: tighter insets so the title keeps its room next to
    // the heart, menu and drag handle.
    final narrow = compact || MediaQuery.sizeOf(context).width < 560;

    return rows.when(
      // Edits re-fetch the window; keep the rows up meanwhile so they can
      // animate to the new order instead of flashing a spinner.
      skipLoadingOnReload: true,
      loading: () => const Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (e, _) => Center(
        child: Text(
          context.l10n.pick('队列加载失败', 'Failed to load queue'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
      data: (data) {
        final items = _present(data);
        if (items.isEmpty) {
          return Center(
            child: Text(
              context.l10n.pick('队列为空', 'Queue is empty'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          );
        }
        return ReorderableListView.builder(
          padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
          buildDefaultDragHandles: false,
          proxyDecorator: (child, index, animation) => Material(
            elevation: 6,
            color: colors.surfaceElevated,
            borderRadius: BorderRadius.circular(LekisRadius.sm),
            child: child,
          ),
          onReorderItem: (oldIndex, newIndex) =>
              _reorder(items, start, oldIndex, newIndex),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final row = items[i];
            final actualIndex = start + i;
            final key = _shownKeys[i];
            final isCurrent = playback.queueIndex != null
                ? actualIndex == playback.queueIndex
                : row.id == playback.trackId;
            final artSize = compact ? 36.0 : 44.0;
            return ListMotionRow(
              key: ValueKey(key),
              motion: _motion,
              index: i,
              child: ListRowCollapse(
                collapsed: _removing.contains(key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: LekisSpacing.xxs / 2,
                  ),
                  child: ListTile(
                    dense: compact,
                    visualDensity: compact ? VisualDensity.compact : null,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: narrow ? LekisSpacing.sm : LekisSpacing.lg,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(LekisRadius.sm),
                    ),
                    tileColor: isCurrent ? colors.accentSoft : null,
                    onTap: () => actions.playQueueAt(actualIndex),
                    leading: SizedBox.square(
                      dimension: artSize,
                      child: TrackArtwork(
                        trackId: row.id,
                        hasArtwork: row.artworkId != null,
                        radius: LekisRadius.artworkList,
                        placeholderLabel: row.title,
                      ),
                    ),
                    title: Text(
                      row.title.isEmpty
                          ? context.l10n.pick('（已删除）', '(Deleted)')
                          : row.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isCurrent ? colors.accent : null,
                        fontWeight: isCurrent ? FontWeight.w600 : null,
                      ),
                    ),
                    subtitle: row.artistLine.isEmpty
                        ? null
                        : Text(
                            row.artistLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isCurrent)
                          Padding(
                            padding: const EdgeInsets.only(
                              right: LekisSpacing.xs,
                            ),
                            child: Icon(
                              Icons.graphic_eq_rounded,
                              size: 18,
                              color: colors.accent,
                            ),
                          ),
                        if (!compact)
                          LovedButton(
                            trackId: row.id,
                            initialLoved: row.loved,
                            size: 18,
                          ),
                        PopupMenuButton<String>(
                          tooltip: context.l10n.pick('队列操作', 'Queue actions'),
                          padding: EdgeInsets.zero,
                          onSelected: (value) {
                            switch (value) {
                              case 'playlist':
                                showAddToPlaylistSheet(
                                  context,
                                  trackId: row.id,
                                  trackTitle: row.title,
                                );
                              case 'remove':
                                _remove(key, actualIndex);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'playlist',
                              child: Text(
                                context.l10n.pick('添加到歌单', 'Add to Playlist'),
                              ),
                            ),
                            PopupMenuItem(
                              value: 'remove',
                              child: Text(
                                context.l10n.pick('从队列移除', 'Remove from Queue'),
                              ),
                            ),
                          ],
                          // A 36 dp row action, matching the heart.
                          child: SizedBox(
                            width: 36,
                            height: 36,
                            child: Icon(
                              Icons.more_horiz_rounded,
                              size: 18,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: LekisSpacing.xs,
                              vertical: LekisSpacing.sm,
                            ),
                            child: Icon(
                              Icons.drag_handle_rounded,
                              size: 20,
                              color: colors.onSurfaceVariant,
                              semanticLabel: context.l10n.pick(
                                '拖动排序',
                                'Drag to reorder',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
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

/// Opens the queue: a right-hand side panel on expanded / wide windows and
/// on every desktop window, the familiar bottom sheet on medium / compact
/// phones and tablets.
Future<void> showQueueSheet(BuildContext context) {
  if (usesQueueSidePanel(context)) return showQueueSidePanel(context);
  return _showQueueBottomSheet(context);
}

Future<void> _showQueueBottomSheet(BuildContext context) {
  return showLekisSheet<void>(
    context,
    heightFactor: 0.62,
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LekisSpacing.xl,
            0,
            LekisSpacing.xl,
            LekisSpacing.sm,
          ),
          child: Consumer(
            builder: (context, ref, _) {
              final length = ref.watch(
                playbackProvider.select((s) => s.queueLength),
              );
              return Row(
                children: [
                  Text(
                    context.l10n.queue,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(width: LekisSpacing.sm),
                  Text(
                    context.l10n.pick('$length 首', '$length tracks'),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: context.lekisColors.onSurfaceVariant),
                  ),
                ],
              );
            },
          ),
        ),
        const Divider(height: 1),
        const Expanded(child: QueueList()),
      ],
    ),
  );
}
