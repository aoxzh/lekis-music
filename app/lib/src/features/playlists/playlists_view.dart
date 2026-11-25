// 歌单列表：普通歌单 + 智能歌单。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart';
import 'package:lekis/src/features/playlists/playlist_cover.dart';
import 'package:lekis/src/features/playlists/playlist_detail_page.dart';
import 'package:lekis/src/features/playlists/playlist_m3u.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/features/playlists/smart_playlist_editor_page.dart';
import 'package:lekis/src/features/playlists/smart_rules_model.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:lekis/src/widgets/action_menu.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lekis/src/features/playlists/playlist_strings.dart';

import '../../l10n/app_l10n.dart';
import '../plugins/online_collections_page.dart';

class PlaylistsView extends ConsumerWidget {
  const PlaylistsView({super.key, this.scope});

  final LibraryScope? scope;

  Future<void> _create(
    BuildContext context,
    WidgetRef ref, {
    required bool smart,
  }) async {
    final name = await askPlaylistName(
      context,
      title: smart
          ? PlaylistStrings.newSmartPlaylist
          : PlaylistStrings.newPlaylist,
      confirm: PlaylistStrings.create,
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
        Navigator.of(context).push(PlaylistDetailPage.route(id, scope: scope));
      }
    } catch (e) {
      if (context.mounted) showPlaylistError(context, e);
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    await importPlaylistM3uFlow(context, ref, scope: scope);
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
                PlaylistStrings.myPlaylists,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Wrap(
                spacing: LekisSpacing.sm,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            OnlineCollectionsPage(pluginId: scope?.pluginId),
                      ),
                    ),
                    icon: const Icon(Icons.public_rounded),
                    label: Text(
                      context.l10n.pick('在线歌单与榜单', 'Online collections'),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _create(context, ref, smart: false),
                    icon: const Icon(Icons.playlist_add_rounded),
                    label: Text(PlaylistStrings.newPlaylist),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _create(context, ref, smart: true),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: Text(PlaylistStrings.newSmartPlaylist),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _import(context, ref),
                    icon: const Icon(Icons.file_open_rounded),
                    label: Text(PlaylistStrings.importPlaylist),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: playlists.whenSkeleton(
            // ListTile with a subtitle (72) + the 1 px row padding each side.
            skeleton: SkeletonListView(
              padding: EdgeInsets.fromLTRB(
                gutter - LekisSpacing.sm,
                LekisSpacing.xs,
                gutter - LekisSpacing.sm,
                0,
              ),
              itemHeight: 74,
            ),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(LekisSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      PlaylistStrings.listLoadFailed,
                      style: theme.textTheme.titleMedium,
                    ),
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
                      child: Text(PlaylistStrings.retry),
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
                      onOpen: () => Navigator.of(context).push(
                        PlaylistDetailPage.route(playlist.id, scope: scope),
                      ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LekisRadius.sm),
        ),
        hoverColor: colors.accentSoft.withValues(alpha: 0.5),
        onTap: onOpen,
        leading: PlaylistCover(
          playlist: playlist,
          size: 48,
          radius: LekisRadius.artworkList,
          iconSize: 24,
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
        trailing: LekisActionMenuButton<String>(
          title: playlist.name,
          tooltip: PlaylistStrings.playlistActions,
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
          actions: () => [
            LekisMenuAction(
              'open',
              Icons.queue_music_rounded,
              PlaylistStrings.open,
            ),
            LekisMenuAction(
              'rename',
              Icons.edit_outlined,
              PlaylistStrings.rename,
            ),
            if (onEditRules != null)
              LekisMenuAction(
                'rules',
                Icons.tune_rounded,
                PlaylistStrings.editRules,
              ),
            LekisMenuAction(
              'delete',
              Icons.delete_outline_rounded,
              PlaylistStrings.delete,
              startsGroup: true,
              destructive: true,
            ),
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
            PlaylistStrings.emptyTitle,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: LekisSpacing.xxs),
          Text(
            PlaylistStrings.emptyMessage,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
