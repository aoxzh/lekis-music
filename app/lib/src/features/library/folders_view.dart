// 资料库的「文件夹」视图：按音源 → 目录 → 子目录浏览，不查整个资料库。
//
// 窄窗口一列到底（面包屑 + 子文件夹 + 直属曲目）；宽窗口左边是目录导航、
// 右边是当前目录的曲目。曲目列表复用 PagedTrackList，目录再大也只按页取。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/library_browse_menu.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/paged_track_list.dart';
import 'package:lekis/src/features/library/widgets/press_feedback.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/layout/adaptive_two_pane.dart';
import 'package:lekis/src/layout/fold.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class FoldersView extends ConsumerWidget {
  const FoldersView({super.key, this.scope = const LibraryScope.local()});

  final LibraryScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedFolderProvider);
    final twoPane = isWideLayout(context) || context.fold.isSeparating;

    if (!twoPane) {
      return FolderRootsList(
        scope: scope,
        onOpen: (root) => _openFolderPage(
          context,
          FolderLocation(
            sourceId: root.sourceId,
            sourceName: root.name,
            path: '',
          ),
          ModalRoute.of(context)!,
        ),
      );
    }

    return AdaptiveTwoPane(
      primaryFraction: 0.36,
      primary: _NavigationPane(location: selected, scope: scope),
      secondary: selected == null
          ? const _PickPrompt()
          : _FolderTracksView(
              key: ValueKey('${selected.sourceId}:${selected.path}'),
              location: selected,
            ),
    );
  }
}

final scopedFolderRootsProvider = FutureProvider.autoDispose
    .family<List<core.FolderRootDto>, LibraryScope>((ref, scope) async {
      final roots = ref.watch(folderRootsProvider.future);
      final sources = ref.watch(sourcesProvider.future);
      final (rows, configs) = await (roots, sources).wait;
      final sourceIds = {
        for (final source in configs)
          if (switch (scope.kind) {
            LibraryScopeKind.local => source.kind == SourceKindDto.local,
            LibraryScopeKind.nas =>
              source.kind != SourceKindDto.local &&
                  source.kind != SourceKindDto.radio &&
                  source.kind != SourceKindDto.plugin,
            LibraryScopeKind.plugin =>
              source.kind == SourceKindDto.plugin &&
                  source.rootPath == scope.pluginId,
          })
            source.id,
      };
      return rows.where((root) => sourceIds.contains(root.sourceId)).toList();
    });

/// 第一层：有曲目的音源。
class FolderRootsList extends ConsumerWidget {
  const FolderRootsList({super.key, required this.scope, required this.onOpen});

  final LibraryScope scope;
  final ValueChanged<core.FolderRootDto> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = scopedFolderRootsProvider(scope);
    final roots = ref.watch(provider);
    final gutter = pageGutterOf(context);
    return roots.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => LoadErrorView(
        error: e,
        onRetry: () {
          ref.invalidate(folderRootsProvider);
          ref.invalidate(sourcesProvider);
        },
      ),
      data: (roots) {
        if (roots.isEmpty) {
          return LibraryEmptyState(
            title: context.l10n.pick('还没有可浏览的文件夹', 'No Browsable Folders Yet'),
            message: context.l10n.pick(
              '添加并扫描一个音源后，这里会按文件夹显示音乐。',
              'Add and scan a music source to browse your music by folder.',
            ),
          );
        }
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(
            gutter - LekisSpacing.sm,
            LekisSpacing.sm,
            gutter - LekisSpacing.sm,
            scrollEndPadding(context),
          ),
          itemExtent: LekisSizes.touchTargetMin + LekisSpacing.md,
          itemCount: roots.length,
          itemBuilder: (context, i) {
            final root = roots[i];
            return _FolderRow(
              icon: scope.kind == LibraryScopeKind.local
                  ? Icons.folder_outlined
                  : Icons.storage_rounded,
              sourceId: root.sourceId,
              path: '',
              name: root.name,
              count: root.trackCount,
              onTap: () => onOpen(root),
            );
          },
        );
      },
    );
  }
}

/// 宽窗口左栏：根目录列表，或当前目录的子文件夹。
class _NavigationPane extends ConsumerWidget {
  const _NavigationPane({required this.location, required this.scope});

  final FolderLocation? location;
  final LibraryScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = this.location;
    if (location == null) {
      return FolderRootsList(
        scope: scope,
        onOpen: (root) {
          ref
              .read(selectedFolderProvider.notifier)
              .set(
                FolderLocation(
                  sourceId: root.sourceId,
                  sourceName: root.name,
                  path: '',
                ),
              );
        },
      );
    }

    final key = folderKeyOf(location);
    final listing = ref.watch(folderListingProvider(key));
    final gutter = pageGutterOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            LekisSpacing.md,
            gutter,
            LekisSpacing.sm,
          ),
          child: FolderBreadcrumb(
            location: location,
            onRoots: () => ref.read(selectedFolderProvider.notifier).set(null),
            onSourceRoot: () => _enter(ref, location, ''),
            onPath: (path) => _enter(ref, location, path),
          ),
        ),
        Expanded(
          child: listing.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => LoadErrorView(
              error: e,
              onRetry: () => ref.invalidate(folderListingProvider(key)),
            ),
            data: (listing) => _FolderChildren(
              location: location,
              listing: listing,
              onOpen: (entry) => _enter(ref, location, entry.path),
            ),
          ),
        ),
      ],
    );
  }

  static void _enter(WidgetRef ref, FolderLocation from, String path) {
    ref
        .read(selectedFolderProvider.notifier)
        .set(
          FolderLocation(
            sourceId: from.sourceId,
            sourceName: from.sourceName,
            path: path,
          ),
        );
  }
}

class _FolderChildren extends StatelessWidget {
  const _FolderChildren({
    required this.location,
    required this.listing,
    required this.onOpen,
  });

  final FolderLocation location;
  final core.FolderListingDto listing;
  final ValueChanged<core.FolderEntryDto> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final gutter = pageGutterOf(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        gutter - LekisSpacing.sm,
        0,
        gutter - LekisSpacing.sm,
        scrollEndPadding(context),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
          child: Text(
            context.l10n.pick(
              '${listing.folders.length} 个文件夹 · 本目录 ${listing.trackCount} 首',
              '${listing.folders.length} folders · ${listing.trackCount} songs here',
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontFeatures: LekisText.tabularFigures,
            ),
          ),
        ),
        const SizedBox(height: LekisSpacing.sm),
        if (listing.folders.isEmpty)
          Padding(
            padding: const EdgeInsets.all(LekisSpacing.sm),
            child: Text(
              context.l10n.pick('没有子文件夹', 'No subfolders'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final entry in listing.folders)
            _FolderRow(
              icon: Icons.folder_outlined,
              sourceId: location.sourceId,
              path: entry.path,
              name: entry.name,
              count: entry.trackCount,
              onTap: () => onOpen(entry),
            ),
      ],
    );
  }
}

/// 面包屑：音源 › 来源名 › 一级目录 › 二级目录……
class FolderBreadcrumb extends StatelessWidget {
  const FolderBreadcrumb({
    super.key,
    required this.location,
    required this.onRoots,
    required this.onSourceRoot,
    required this.onPath,
  });

  final FolderLocation location;
  final VoidCallback onRoots;
  final VoidCallback onSourceRoot;
  final ValueChanged<String> onPath;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final segments = location.segments;

    Widget crumb(String label, VoidCallback onTap) => TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, LekisSizes.touchTargetMin),
        padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
        foregroundColor: colors.onSurfaceVariant,
        textStyle: theme.textTheme.bodyMedium,
      ),
      onPressed: onTap,
      child: Text(label),
    );

    final children = <Widget>[
      crumb(context.l10n.pick('音源', 'Sources'), onRoots),
      Icon(
        Icons.chevron_right_rounded,
        size: LekisSpacing.lg,
        color: colors.onSurfaceVariant,
      ),
    ];

    if (segments.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
          child: Text(
            location.sourceName,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    } else {
      children.add(crumb(location.sourceName, onSourceRoot));
      for (var i = 1; i <= segments.length; i++) {
        children.add(
          Icon(
            Icons.chevron_right_rounded,
            size: LekisSpacing.lg,
            color: colors.onSurfaceVariant,
          ),
        );
        final label = segments[i - 1];
        if (i == segments.length) {
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        } else {
          final path = location.pathAt(i);
          children.add(crumb(label, () => onPath(path)));
        }
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: children),
    );
  }
}

void _openFolderPage(
  BuildContext context,
  FolderLocation location,
  ModalRoute<dynamic> origin,
) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: RouteSettings(arguments: location),
      builder: (_) => _FolderPage(location: location, origin: origin),
    ),
  );
}

class _FolderPage extends ConsumerWidget {
  const _FolderPage({required this.location, required this.origin});

  final FolderLocation location;
  final ModalRoute<dynamic> origin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    FolderLocation at(String path) => FolderLocation(
      sourceId: location.sourceId,
      sourceName: location.sourceName,
      path: path,
    );
    void backTo(String? path) {
      final target = path == null ? null : at(path);
      Navigator.of(context).popUntil(
        (route) =>
            route == origin ||
            (target != null && route.settings.arguments == target) ||
            route.isFirst,
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(location.name)),
      body: PagedTrackList(
        list: ref.watch(folderTracksListProvider(folderKeyOf(location))),
        showHeaderWhenEmpty: true,
        playContext: PlayContextDto.folder(
          sourceId: location.sourceId,
          path: location.path,
        ),
        header: _FolderHeader(
          location: location,
          onBackTo: backTo,
          onOpen: (path) => _openFolderPage(context, at(path), origin),
        ),
        empty: const _NoDirectTracks(),
      ),
    );
  }
}

class _FolderTracksView extends ConsumerWidget {
  const _FolderTracksView({super.key, required this.location});

  final FolderLocation location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = folderKeyOf(location);
    final list = ref.watch(folderTracksListProvider(key));
    return PagedTrackList(
      list: list,
      showHeaderWhenEmpty: true,
      playContext: PlayContextDto.folder(
        sourceId: location.sourceId,
        path: location.path,
      ),
      header: _FolderHeader(location: location),
      empty: const _NoDirectTracks(),
    );
  }
}

/// 目录头部：面包屑 + 目录名 + 播放按钮 + 计数 +（窄窗口的）子文件夹列表。
class _FolderHeader extends ConsumerWidget {
  const _FolderHeader({required this.location, this.onBackTo, this.onOpen});

  final FolderLocation location;
  final ValueChanged<String?>? onBackTo;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = folderKeyOf(location);
    final listing = ref.watch(folderListingProvider(key));
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final gutter = pageGutterOf(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, LekisSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onBackTo != null)
            FolderBreadcrumb(
              location: location,
              onRoots: () => onBackTo!(null),
              onSourceRoot: () => onBackTo!(''),
              onPath: onBackTo!,
            ),
          const SizedBox(height: LekisSpacing.xs),
          Row(
            children: [
              if (onOpen == null) ...[
                Expanded(
                  child: Text(
                    location.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                const SizedBox(width: LekisSpacing.sm),
              ],
              listing.when(
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
                data: (listing) => _PlayFolderButton(
                  location: location,
                  trackCount: listing.trackCount,
                ),
              ),
            ],
          ),
          const SizedBox(height: LekisSpacing.xxs),
          listing.when(
            loading: () => Text(
              context.l10n.pick('正在读取文件夹…', 'Loading folder…'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            error: (_, _) => _InlineError(
              onRetry: () => ref.invalidate(folderListingProvider(key)),
            ),
            data: (listing) {
              final folders = onOpen != null ? listing.folders : const [];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    onOpen != null
                        ? context.l10n.pick(
                            '${listing.folders.length} 个文件夹 · 本目录 ${listing.trackCount} 首',
                            '${listing.folders.length} folders · ${listing.trackCount} songs here',
                          )
                        : context.l10n.pick(
                            '本目录 ${listing.trackCount} 首',
                            '${listing.trackCount} songs here',
                          ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontFeatures: LekisText.tabularFigures,
                    ),
                  ),
                  if (onOpen != null && folders.isNotEmpty) ...[
                    const SizedBox(height: LekisSpacing.sm),
                    for (final entry in folders)
                      _FolderRow(
                        icon: Icons.folder_outlined,
                        name: entry.name,
                        count: entry.trackCount,
                        sourceId: location.sourceId,
                        path: entry.path,
                        onTap: () => onOpen!(entry.path),
                      ),
                    const Divider(height: LekisSpacing.xl),
                  ] else if (onOpen != null) ...[
                    const SizedBox(height: LekisSpacing.xs),
                    Text(
                      context.l10n.pick('没有子文件夹', 'No subfolders'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PlayFolderButton extends ConsumerWidget {
  const _PlayFolderButton({required this.location, required this.trackCount});

  final FolderLocation location;
  final int trackCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, LekisSizes.touchTargetMin),
      ),
      onPressed: trackCount == 0
          ? null
          : () => _playFolder(context, ref, location.sourceId, location.path),
      icon: const Icon(Icons.play_arrow_rounded),
      label: Text(context.l10n.pick('播放文件夹', 'Play Folder')),
    );
  }
}

Future<void> _playFolder(
  BuildContext context,
  WidgetRef ref,
  int sourceId,
  String path, {
  bool checkContents = false,
}) async {
  // Row counts include descendants. Folder playback only includes direct tracks.
  if (checkContents) {
    try {
      final listing = await ref.read(
        folderListingProvider((sourceId: sourceId, path: path)).future,
      );
      if (!context.mounted) return;
      if (listing.trackCount == 0) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick(
                '这个文件夹没有直属曲目',
                'No songs directly in this folder',
              ),
            ),
          ),
        );
        return;
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return;
    }
  }
  if (!context.mounted) return;
  final ok = await ref.read(playerActionsProvider).playFolder(sourceId, path);
  if (!ok && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.pick('无法播放这个文件夹', 'Cannot play this folder'),
        ),
      ),
    );
  }
}

class _FolderRow extends ConsumerWidget {
  const _FolderRow({
    required this.icon,
    required this.sourceId,
    required this.path,
    required this.name,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final int sourceId;
  final String path;
  final String name;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return PressFeedback(
      child: InkWell(
        borderRadius: BorderRadius.circular(LekisRadius.sm),
        onTap: onTap,
        child: SizedBox(
          height: LekisSizes.touchTargetMin + LekisSpacing.sm,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
            child: Row(
              children: [
                Icon(icon, color: colors.accent),
                const SizedBox(width: LekisSpacing.md),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                Text(
                  context.l10n.pick('$count 首', '$count songs'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: LekisText.tabularFigures,
                  ),
                ),
                LibraryBrowseMenu(
                  title: name,
                  subtitle: context.l10n.pick('$count 首歌曲', '$count songs'),
                  openLabel: context.l10n.pick('打开文件夹', 'Open folder'),
                  icon: Icons.folder_open_rounded,
                  onOpen: onTap,
                  playLabel: context.l10n.pick(
                    '播放本层歌曲',
                    'Play songs in this folder',
                  ),
                  onPlay: count == 0
                      ? null
                      : () => _playFolder(
                          context,
                          ref,
                          sourceId,
                          path,
                          checkContents: true,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoDirectTracks extends StatelessWidget {
  const _NoDirectTracks();

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LekisSpacing.lg,
        LekisSpacing.xl,
        LekisSpacing.lg,
        LekisSpacing.xl,
      ),
      child: Column(
        children: [
          Icon(
            Icons.music_off_outlined,
            size: LekisSpacing.xxxl,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Text(
            context.l10n.pick(
              '这个文件夹没有直属曲目',
              'No songs directly in this folder',
            ),
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return Row(
      children: [
        Expanded(
          child: Text(
            context.l10n.pick('读取文件夹失败', 'Failed to read folder'),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.danger),
          ),
        ),
        TextButton(
          onPressed: onRetry,
          child: Text(context.l10n.pick('重试', 'Retry')),
        ),
      ],
    );
  }
}

class _PickPrompt extends StatelessWidget {
  const _PickPrompt();

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_open_outlined,
            size: LekisSpacing.xxxl,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Text(
            context.l10n.pick(
              '选择一个音源，按文件夹浏览',
              'Select a source to browse by folder',
            ),
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
