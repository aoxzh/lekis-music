// Shared playlist dialogs / commands used by the list and detail pages.

import 'dart:async';

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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(PlaylistStrings.duplicateSmartUnsupported)),
      );
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
