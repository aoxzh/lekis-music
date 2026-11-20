// 歌单列表：普通歌单 + 智能歌单。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart';
import 'package:lekis/src/features/playlists/playlist_detail_page.dart';
import 'package:lekis/src/features/playlists/playlist_m3u.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/features/playlists/smart_playlist_editor_page.dart';
import 'package:lekis/src/features/playlists/smart_rules_model.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class PlaylistsView extends ConsumerWidget {
  const PlaylistsView({super.key});

  Future<void> _create(
    BuildContext context,
    WidgetRef ref, {
    required bool smart,
  }) async {
    final name = await askPlaylistName(
      context,
      title: smart ? '新建智能歌单' : '新建歌单',
      confirm: '创建',
    );
    if (name == null || !context.mounted) return;
    try {
      final id = await core.createPlaylist(name: name);
      if (smart) {
        await core.setPlaylistRules(
          playlistId: id,
          rules: smartBuildRules(root: smartEmptyGroup(RuleGroupKindDto.all)),
        );
        if (!context.mounted) return;
        Navigator.of(context)
            .push(SmartPlaylistEditorPage.route(id, name: name));
      } else {
        if (!context.mounted) return;
        Navigator.of(context).push(PlaylistDetailPage.route(id));
      }
    } catch (e) {
      if (context.mounted) showPlaylistError(context, e);
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    await importPlaylistM3uFlow(context, ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final gutter = pageGutterOf(context);
    final playlists = ref.watch(playlistsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            LekisSpacing.sm,
            gutter,
            LekisSpacing.sm,
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: LekisSpacing.md,
            runSpacing: LekisSpacing.sm,
            children: [
              Text(
                '我的歌单',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Wrap(
                spacing: LekisSpacing.sm,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _create(context, ref, smart: false),
                    icon: const Icon(Icons.playlist_add_rounded),
                    label: const Text('新建歌单'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _create(context, ref, smart: true),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: const Text('新建智能歌单'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _import(context, ref),
                    icon: const Icon(Icons.file_open_rounded),
                    label: const Text('导入歌单'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: playlists.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(LekisSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('歌单加载失败', style: theme.textTheme.titleMedium),
                    const SizedBox(height: LekisSpacing.xs),
                    Text(
                      describeCoreError(e),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: LekisSpacing.md),
                    OutlinedButton(
                      onPressed: () => ref.invalidate(playlistsProvider),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
            data: (items) {
              if (items.isEmpty) return const _EmptyPlaylists();
              return RefreshIndicator(
                onRefresh: () async => ref.invalidate(playlistsProvider),
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    gutter - LekisSpacing.sm,
                    LekisSpacing.xs,
                    gutter - LekisSpacing.sm,
                    scrollEndPadding(context),
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final playlist = items[i];
                    return _PlaylistTile(
                      playlist: playlist,
                      onOpen: () =>
                          Navigator.of(context)
                              .push(PlaylistDetailPage.route(playlist.id)),
                      onRename: () =>
                          renamePlaylistFlow(context, ref, playlist),
                      onDelete: () async {
                        final deleted = await deletePlaylistFlow(
                          context,
                          ref,
                          playlist,
                        );
                        if (deleted) ref.invalidate(playlistsProvider);
                      },
                      onEditRules: playlist.kind == PlaylistKindDto.smart
                          ? () => Navigator.of(context).push(
                              SmartPlaylistEditorPage.route(
                                playlist.id,
                                name: playlist.name,
                              ),
                            )
                          : null,
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    required this.playlist,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    this.onEditRules,
  });

  final PlaylistDto playlist;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback? onEditRules;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final smart = playlist.kind == PlaylistKindDto.smart;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LekisRadius.sm),
        ),
        hoverColor: colors.accentSoft.withValues(alpha: 0.5),
        onTap: onOpen,
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: smart
                ? colors.accentSoft
                : colors.surfaceVariant.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(LekisRadius.artworkList),
          ),
          child: Icon(
            smart ? Icons.auto_awesome_rounded : Icons.queue_music_rounded,
            color: smart ? colors.accent : colors.onSurfaceVariant,
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: LekisSpacing.sm),
            PlaylistKindChip(playlist: playlist),
          ],
        ),
        subtitle: Text(
          playlistSubtitle(playlist),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          tooltip: '歌单操作',
          onSelected: (value) {
            switch (value) {
              case 'open':
                onOpen();
              case 'rename':
                onRename();
              case 'rules':
                onEditRules?.call();
              case 'delete':
                onDelete();
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'open', child: Text('打开')),
            const PopupMenuItem(value: 'rename', child: Text('重命名')),
            if (onEditRules != null)
              const PopupMenuItem(value: 'rules', child: Text('编辑规则')),
            const PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
      ),
    );
  }
}

class _EmptyPlaylists extends StatelessWidget {
  const _EmptyPlaylists();

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.queue_music_rounded,
            size: LekisSpacing.xxxl,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Text(
            '还没有歌单',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: LekisSpacing.xxs),
          Text(
            '新建普通歌单，或者用规则建一个智能歌单',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
