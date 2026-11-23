// Shared playlist dialogs / commands used by the list and detail pages.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/error.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lekis/src/features/playlists/playlist_strings.dart';

/// 弹窗问歌单名；取消或空名字返回 `null`。
Future<String?> askPlaylistName(
  BuildContext context, {
  required String title,
  String initial = '',
  String? confirm,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showLekisPanel<String>(
    context,
    dismissible: false,
    builder: (_) {
      String? error;
      return StatefulBuilder(
        builder: (context, setState) => LekisPanel(
          title: title,
          error: error,
          body: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(labelText: PlaylistStrings.nameLabel),
            onSubmitted: (_) {
              final name = controller.text.trim();
              if (name.isEmpty) {
                setState(() => error = PlaylistStrings.nameEmpty);
              } else {
                Navigator.of(context).pop(name);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(PlaylistStrings.cancel),
            ),
            FilledButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setState(() => error = PlaylistStrings.nameEmpty);
                  return;
                }
                Navigator.of(context).pop(name);
              },
              child: Text(confirm ?? PlaylistStrings.ok),
            ),
          ],
        ),
      );
    },
  );
  controller.dispose();
  return result;
}

Future<bool> confirmDeletePlaylist(
  BuildContext context,
  PlaylistDto playlist,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(PlaylistStrings.deleteTitle),
      content: Text(
        playlist.kind == PlaylistKindDto.smart
            ? PlaylistStrings.deleteSmartBody(playlist.name)
            : PlaylistStrings.deleteBody(playlist.name),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(PlaylistStrings.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(PlaylistStrings.delete),
        ),
      ],
    ),
  );
  return ok ?? false;
}

void showPlaylistError(BuildContext context, Object error) {
  final text = error is CoreError ? error.detail : '$error';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(PlaylistStrings.actionFailed(text))));
}

/// 在核心里把整个歌单放进队列（智能歌单会实时求值）。
Future<void> playPlaylistContext(
  BuildContext context,
  PlaylistDto playlist, {
  int startIndex = 0,
}) async {
  try {
    await core.playContext(
      context: PlayContextDto.playlist(playlistId: playlist.id),
      startIndex: startIndex,
    );
  } catch (e) {
    if (context.mounted) showPlaylistError(context, e);
  }
}

/// 删除并返回是否成功；调用方决定要不要 pop 详情页。
Future<bool> deletePlaylistFlow(
  BuildContext context,
  WidgetRef ref,
  PlaylistDto playlist,
) async {
  if (!await confirmDeletePlaylist(context, playlist)) return false;
  try {
    await core.deletePlaylist(playlistId: playlist.id);
    // 事件会刷新 provider；这里主动失效一次，保证详情页立刻感知。
    ref.invalidate(playlistsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(PlaylistStrings.deleted(playlist.name))),
        );
    }
    return true;
  } catch (e) {
    if (context.mounted) showPlaylistError(context, e);
    return false;
  }
}

/// 重命名；成功返回新名字。
Future<String?> renamePlaylistFlow(
  BuildContext context,
  WidgetRef ref,
  PlaylistDto playlist,
) async {
  final name = await askPlaylistName(
    context,
    title: PlaylistStrings.renameTitle,
    initial: playlist.name,
    confirm: PlaylistStrings.save,
  );
  if (name == null) return null;
  try {
    await core.renamePlaylist(playlistId: playlist.id, name: name);
    ref.invalidate(playlistsProvider);
    return name;
  } catch (e) {
    if (context.mounted) showPlaylistError(context, e);
    return null;
  }
}

/// 歌单副标题：智能歌单显示"实时规则"，普通歌单显示曲目数。
String playlistSubtitle(PlaylistDto playlist) =>
    playlist.kind == PlaylistKindDto.smart
    ? PlaylistStrings.smartSubtitle
    : PlaylistStrings.songCount(playlist.trackCount);

/// Duplicate a regular playlist into a new one, preserving order.
Future<void> duplicatePlaylistFlow(
  BuildContext context,
  WidgetRef ref,
  PlaylistDto playlist,
) async {
  if (playlist.kind == PlaylistKindDto.smart) {
    try {
      final rules = await core.getPlaylistRules(playlistId: playlist.id);
      if (rules == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(PlaylistStrings.duplicateSmartUnsupported),
              ),
            );
        }
        return;
      }
      if (!context.mounted) return;
      final name = await askPlaylistName(
        context,
        title: PlaylistStrings.duplicateTitle,
        initial: PlaylistStrings.duplicateName(playlist.name),
        confirm: PlaylistStrings.create,
      );
      if (name == null || !context.mounted) return;
      final newId = await core.createPlaylist(name: name);
      try {
        await core.setPlaylistRules(playlistId: newId, rules: rules);
      } catch (_) {
        try {
          await core.deletePlaylist(playlistId: newId);
        } catch (_) {
          // Best-effort cleanup; the original error is the useful one.
        }
        rethrow;
      }
      ref.invalidate(playlistsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(PlaylistStrings.duplicatedSmart(name))),
          );
      }
    } catch (e) {
      if (context.mounted) showPlaylistError(context, e);
    }
    return;
  }
  final name = await askPlaylistName(
    context,
    title: PlaylistStrings.duplicateTitle,
    initial: PlaylistStrings.duplicateName(playlist.name),
    confirm: PlaylistStrings.create,
  );
  if (name == null || !context.mounted) return;
  final progress = ValueNotifier<int>(0);
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(PlaylistStrings.duplicating),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, done, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: LekisSpacing.md),
              Text('$done'),
            ],
          ),
        ),
      ),
    ),
  );
  var saved = 0;
  try {
    final newId = await core.createPlaylist(name: name);
    var offset = 0;
    while (true) {
      final rows = await core.playlistItems(
        playlistId: playlist.id,
        offset: offset,
        limit: 200,
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        await core.addToPlaylist(playlistId: newId, trackUid: row.trackUid);
        saved++;
        progress.value = saved;
      }
      offset += rows.length;
    }
    ref.invalidate(playlistsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(PlaylistStrings.duplicated(name, saved))),
        );
    }
  } catch (e) {
    if (context.mounted) showPlaylistError(context, e);
  } finally {
    if (navigator.mounted && navigator.canPop()) navigator.pop();
    progress.dispose();
  }
}

enum PlaylistSortMode {
  title,
  artist,
  album,
  added,
  duration,
  reverse,
  shuffle,
}

String _sortLabel(PlaylistSortMode mode) => switch (mode) {
  PlaylistSortMode.title => PlaylistStrings.sortByTitle,
  PlaylistSortMode.artist => PlaylistStrings.sortByArtist,
  PlaylistSortMode.album => PlaylistStrings.sortByAlbum,
  PlaylistSortMode.added => PlaylistStrings.sortByAdded,
  PlaylistSortMode.duration => PlaylistStrings.sortByDuration,
  PlaylistSortMode.reverse => PlaylistStrings.reverseOrder,
  PlaylistSortMode.shuffle => PlaylistStrings.shuffleOrder,
};

int _compareEntry(
  PlaylistEntryDto a,
  PlaylistEntryDto b,
  PlaylistSortMode mode,
) {
  final ta = a.track;
  final tb = b.track;
  int text(String? x, String? y) =>
      (x ?? '').toLowerCase().compareTo((y ?? '').toLowerCase());
  final result = switch (mode) {
    PlaylistSortMode.title => text(ta?.title, tb?.title),
    PlaylistSortMode.artist => text(ta?.artistLine, tb?.artistLine),
    PlaylistSortMode.album => text(ta?.albumTitle, tb?.albumTitle),
    PlaylistSortMode.added => a.addedAt.toInt().compareTo(b.addedAt.toInt()),
    PlaylistSortMode.duration => (ta?.durationMs.toInt() ?? 0).compareTo(
      tb?.durationMs.toInt() ?? 0,
    ),
    PlaylistSortMode.reverse || PlaylistSortMode.shuffle => 0,
  };
  return result != 0 ? result : a.trackUid.compareTo(b.trackUid);
}

/// Pick a sort order for a static playlist and apply it.
///
/// The core only exposes "move this item"; moving every item to the end in
/// the target order sorts the whole list without re-reading position keys
/// after each call.
Future<void> showPlaylistSortSheet(
  BuildContext context,
  WidgetRef ref,
  PlaylistDto playlist,
  List<PlaylistEntryDto> rows,
) async {
  final mode = await showModalBottomSheet<PlaylistSortMode>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      ListTile item(PlaylistSortMode value, IconData icon, String label) =>
          ListTile(
            leading: Icon(icon),
            title: Text(label),
            onTap: () => Navigator.of(sheet).pop(value),
          );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LekisSpacing.lg,
                0,
                LekisSpacing.lg,
                LekisSpacing.sm,
              ),
              child: Text(
                PlaylistStrings.sortPlaylist,
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
            ),
            item(
              PlaylistSortMode.title,
              Icons.sort_by_alpha_rounded,
              PlaylistStrings.sortByTitle,
            ),
            item(
              PlaylistSortMode.artist,
              Icons.person_outline_rounded,
              PlaylistStrings.sortByArtist,
            ),
            item(
              PlaylistSortMode.album,
              Icons.album_outlined,
              PlaylistStrings.sortByAlbum,
            ),
            item(
              PlaylistSortMode.added,
              Icons.schedule_rounded,
              PlaylistStrings.sortByAdded,
            ),
            item(
              PlaylistSortMode.duration,
              Icons.timer_outlined,
              PlaylistStrings.sortByDuration,
            ),
            item(
              PlaylistSortMode.reverse,
              Icons.swap_vert_rounded,
              PlaylistStrings.reverseOrder,
            ),
            item(
              PlaylistSortMode.shuffle,
              Icons.shuffle_rounded,
              PlaylistStrings.shuffleOrder,
            ),
          ],
        ),
      );
    },
  );
  if (mode == null || !context.mounted) return;
  await sortPlaylistFlow(context, ref, playlist, rows, mode);
}

Future<void> sortPlaylistFlow(
  BuildContext context,
  WidgetRef ref,
  PlaylistDto playlist,
  List<PlaylistEntryDto> rows,
  PlaylistSortMode mode,
) async {
  if (rows.length < 2) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(PlaylistStrings.nothingToSort)));
    return;
  }
  final target = switch (mode) {
    PlaylistSortMode.title ||
    PlaylistSortMode.artist ||
    PlaylistSortMode.album ||
    PlaylistSortMode.added ||
    PlaylistSortMode.duration => [
      ...rows,
    ]..sort((a, b) => _compareEntry(a, b, mode)),
    PlaylistSortMode.reverse => rows.reversed.toList(),
    PlaylistSortMode.shuffle => [...rows]..shuffle(),
  };
  var same = true;
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].positionKey != target[i].positionKey) {
      same = false;
      break;
    }
  }
  if (same) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(PlaylistStrings.alreadySorted)));
    return;
  }

  final label = _sortLabel(mode);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(PlaylistStrings.sortConfirmTitle),
      content: Text(PlaylistStrings.sortConfirmBody(label)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(PlaylistStrings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(PlaylistStrings.sortPlaylist),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final progress = ValueNotifier<int>(0);
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(PlaylistStrings.sortingPlaylist),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, done, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: target.isEmpty ? 0 : done / target.length,
              ),
              const SizedBox(height: LekisSpacing.md),
              Text('$done / ${target.length}'),
            ],
          ),
        ),
      ),
    ),
  );

  var failed = 0;
  try {
    for (final entry in target) {
      try {
        await core.movePlaylistItem(
          playlistId: playlist.id,
          positionKey: entry.positionKey,
        );
      } catch (_) {
        failed++;
      }
      progress.value++;
    }
    ref.invalidate(playlistEntriesProvider(playlist.id));
    ref.invalidate(playlistsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              failed == 0
                  ? PlaylistStrings.sortedPlaylist
                  : PlaylistStrings.sortPartial(failed),
            ),
          ),
        );
    }
  } catch (e) {
    if (context.mounted) showPlaylistError(context, e);
  } finally {
    if (navigator.mounted && navigator.canPop()) navigator.pop();
    progress.dispose();
  }
}

Future<void> _copyLines(
  BuildContext context,
  List<String> lines, {
  required String emptyMessage,
  required String Function(int count) copiedMessage,
  required String Function(Object error) failedMessage,
}) async {
  if (lines.isEmpty) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(emptyMessage)));
    return;
  }
  try {
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(copiedMessage(lines.length))));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failedMessage(e))));
  }
}

Future<void> copyPlaylistAsText(
  BuildContext context,
  List<PlaylistEntryDto> rows,
) {
  return _copyLines(
    context,
    [
      for (var i = 0; i < rows.length; i++)
        '${i + 1}. ${rows[i].track?.title ?? PlaylistStrings.trackUnavailable}'
            '${(rows[i].track?.artistLine ?? '').isEmpty ? '' : ' — ${rows[i].track!.artistLine}'}',
    ],
    emptyMessage: PlaylistStrings.nothingToCopy,
    copiedMessage: PlaylistStrings.copiedPlaylist,
    failedMessage: (e) => PlaylistStrings.copyPlaylistFailed('$e'),
  );
}

Future<void> copyPlaylistTracksAsText(
  BuildContext context,
  List<TrackRowDto> tracks,
) {
  return _copyLines(
    context,
    [
      for (var i = 0; i < tracks.length; i++)
        '${i + 1}. ${tracks[i].title}'
            '${tracks[i].artistLine.isEmpty ? '' : ' — ${tracks[i].artistLine}'}',
    ],
    emptyMessage: PlaylistStrings.nothingToCopy,
    copiedMessage: PlaylistStrings.copiedPlaylist,
    failedMessage: (e) => PlaylistStrings.copyPlaylistFailed('$e'),
  );
}

Future<void> copyTrackListAsText(
  BuildContext context,
  List<TrackRowDto> tracks,
) {
  return _copyLines(
    context,
    [
      for (var i = 0; i < tracks.length; i++)
        '${i + 1}. ${tracks[i].title}'
            '${tracks[i].artistLine.isEmpty ? '' : ' — ${tracks[i].artistLine}'}',
    ],
    emptyMessage: PlaylistStrings.noTracksToCopy,
    copiedMessage: PlaylistStrings.copiedTrackList,
    failedMessage: (e) => PlaylistStrings.copyTracksFailed('$e'),
  );
}

Future<void> removePlaylistDuplicatesFlow(
  BuildContext context,
  WidgetRef ref,
  PlaylistDto playlist,
  List<PlaylistEntryDto> rows,
) async {
  final seen = <String>{};
  final duplicates = <PlaylistEntryDto>[];
  for (final row in rows) {
    if (!seen.add(row.trackUid)) duplicates.add(row);
  }
  if (duplicates.isEmpty) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(PlaylistStrings.noDuplicates)));
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(PlaylistStrings.removeDuplicatesTitle),
      content: Text(PlaylistStrings.removeDuplicatesBody(duplicates.length)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(PlaylistStrings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(PlaylistStrings.removeDuplicates),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final progress = ValueNotifier<int>(0);
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(PlaylistStrings.removingDuplicates),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, done, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: duplicates.isEmpty ? 0 : done / duplicates.length,
              ),
              const SizedBox(height: LekisSpacing.md),
              Text('$done / ${duplicates.length}'),
            ],
          ),
        ),
      ),
    ),
  );

  var removed = 0;
  var failed = 0;
  try {
    for (final entry in duplicates) {
      try {
        await core.removeFromPlaylist(
          playlistId: playlist.id,
          positionKey: entry.positionKey,
        );
        removed++;
      } catch (_) {
        failed++;
      }
      progress.value++;
    }
    ref.invalidate(playlistEntriesProvider(playlist.id));
    ref.invalidate(playlistsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(PlaylistStrings.duplicatesRemoved(removed, failed)),
          ),
        );
    }
  } catch (e) {
    if (context.mounted) showPlaylistError(context, e);
  } finally {
    if (navigator.mounted && navigator.canPop()) navigator.pop();
    progress.dispose();
  }
}

/// 长按 / 菜单里用的小标签样式。
class PlaylistKindChip extends StatelessWidget {
  const PlaylistKindChip({super.key, required this.playlist});

  final PlaylistDto playlist;

  @override
  Widget build(BuildContext context) {
    final smart = playlist.kind == PlaylistKindDto.smart;
    final colors = context.lekisColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: smart
            ? colors.accentSoft
            : colors.surfaceVariant.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(LekisRadius.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.sm,
          vertical: LekisSpacing.xxs,
        ),
        child: Text(
          smart ? PlaylistStrings.kindSmart : PlaylistStrings.kindPlaylist,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: smart ? colors.accent : colors.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
