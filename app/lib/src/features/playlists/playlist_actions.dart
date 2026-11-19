// Shared playlist dialogs / commands used by the list and detail pages.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/error.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// 弹窗问歌单名；取消或空名字返回 `null`。
Future<String?> askPlaylistName(
  BuildContext context, {
  required String title,
  String initial = '',
  String confirm = '确定',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) {
      String? error;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(labelText: '歌单名称', errorText: error),
            onSubmitted: (_) {
              final name = controller.text.trim();
              if (name.isEmpty) {
                setState(() => error = '名称不能为空');
              } else {
                Navigator.of(context).pop(name);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setState(() => error = '名称不能为空');
                  return;
                }
                Navigator.of(context).pop(name);
              },
              child: Text(confirm),
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
      title: const Text('删除歌单？'),
      content: Text(
        playlist.kind == PlaylistKindDto.smart
            ? '“${playlist.name}”的规则和内容都会删除。已同步到其它设备的删除会写墓碑。'
            : '“${playlist.name}”会从所有设备删除，曲目文件不会受影响。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
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
    ..showSnackBar(SnackBar(content: Text('操作失败：$text')));
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
        ..showSnackBar(SnackBar(content: Text('已删除“${playlist.name}”')));
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
    title: '重命名歌单',
    initial: playlist.name,
    confirm: '保存',
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
    ? '智能歌单 · 规则实时求值'
    : '${playlist.trackCount} 首歌曲';

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
          smart ? '智能' : '歌单',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: smart ? colors.accent : colors.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
