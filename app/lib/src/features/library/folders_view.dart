// 资料库的「文件夹」视图：按音源 → 目录 → 子目录浏览，不查整个资料库。
//
// 窄窗口一列到底（面包屑 + 子文件夹 + 直属曲目）；宽窗口左边是目录导航、
// 右边是当前目录的曲目。曲目列表复用 PagedTrackList，目录再大也只按页取。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/paged_track_list.dart';
import 'package:lekis/src/features/library/widgets/press_feedback.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/layout/adaptive_two_pane.dart';
import 'package:lekis/src/layout/fold.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class FoldersView extends ConsumerWidget {
  const FoldersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedFolderProvider);
    final twoPane = isWideLayout(context) || context.fold.isSeparating;

    if (!twoPane) {
      if (selected == null) {
        return FolderRootsList(onOpen: (root) => _openRoot(ref, root));
      }
      return _SingleFolderView(
        key: ValueKey('${selected.sourceId}:${selected.path}'),
        location: selected,
      );
    }

    return AdaptiveTwoPane(
      primaryFraction: 0.36,
      primary: _NavigationPane(location: selected),
      secondary: selected == null
          ? const _PickPrompt()
          : _FolderTracksView(
              key: ValueKey('${selected.sourceId}:${selected.path}'),
              location: selected,
            ),
    );
  }

  static void _openRoot(WidgetRef ref, core.FolderRootDto root) {
    ref
        .read(selectedFolderProvider.notifier)
        .set(
          FolderLocation(
            sourceId: root.sourceId,
            sourceName: root.name,
            path: '',
          ),
        );
  }
}

/// 第一层：有曲目的音源。
class FolderRootsList extends ConsumerWidget {
  const FolderRootsList({super.key, required this.onOpen});

  final ValueChanged<core.FolderRootDto> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roots = ref.watch(folderRootsProvider);
    final gutter = pageGutterOf(context);
    return roots.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => LoadErrorView(
        error: e,
        onRetry: () => ref.invalidate(folderRootsProvider),
      ),
      data: (roots) {
        if (roots.isEmpty) {
          return const LibraryEmptyState(
            title: '还没有可浏览的文件夹',
            message: '添加并扫描一个音源后，这里会按文件夹显示音乐。',
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
              icon: Icons.lan_outlined,
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
  const _NavigationPane({required this.location});

  final FolderLocation? location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = this.location;
    if (location == null) {
      return FolderRootsList(
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
            '${listing.folders.length} 个文件夹 · 本目录 ${listing.trackCount} 首',
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
              '没有子文件夹',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final entry in listing.folders)
            _FolderRow(
              icon: Icons.folder_outlined,
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
      crumb('音源', onRoots),
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

class _SingleFolderView extends ConsumerWidget {
  const _SingleFolderView({super.key, required this.location});

  final FolderLocation location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = folderKeyOf(location);
    final list = ref.watch(folderTracksListProvider(key));
    return PagedTrackList(
      list: list,
      showHeaderWhenEmpty: true,
      header: _FolderHeader(
        location: location,
        showBreadcrumb: true,
        showFolders: true,
      ),
      empty: const _NoDirectTracks(),
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
      header: _FolderHeader(
        location: location,
        showBreadcrumb: false,
        showFolders: false,
      ),
      empty: const _NoDirectTracks(),
    );
  }
}

/// 目录头部：面包屑 + 目录名 + 播放按钮 + 计数 +（窄窗口的）子文件夹列表。
class _FolderHeader extends ConsumerWidget {
  const _FolderHeader({
    required this.location,
    required this.showBreadcrumb,
    required this.showFolders,
  });

  final FolderLocation location;
  final bool showBreadcrumb;
  final bool showFolders;

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
          if (showBreadcrumb)
            FolderBreadcrumb(
              location: location,
              onRoots: () =>
                  ref.read(selectedFolderProvider.notifier).set(null),
              onSourceRoot: () => _enter(ref, ''),
              onPath: (path) => _enter(ref, path),
            ),
          const SizedBox(height: LekisSpacing.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  location.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              const SizedBox(width: LekisSpacing.sm),
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
              '正在读取文件夹…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            error: (_, _) => _InlineError(
              onRetry: () => ref.invalidate(folderListingProvider(key)),
            ),
            data: (listing) {
              final folders = showFolders ? listing.folders : const [];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    showFolders
                        ? '${listing.folders.length} 个文件夹 · 本目录 ${listing.trackCount} 首'
                        : '本目录 ${listing.trackCount} 首',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontFeatures: LekisText.tabularFigures,
                    ),
                  ),
                  if (showFolders && folders.isNotEmpty) ...[
                    const SizedBox(height: LekisSpacing.sm),
                    for (final entry in folders)
                      _FolderRow(
                        icon: Icons.folder_outlined,
                        name: entry.name,
                        count: entry.trackCount,
                        onTap: () => _enter(ref, entry.path),
                      ),
                    const Divider(height: LekisSpacing.xl),
                  ] else if (showFolders) ...[
                    const SizedBox(height: LekisSpacing.xs),
                    Text(
                      '没有子文件夹',
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

  void _enter(WidgetRef ref, String path) {
    ref
        .read(selectedFolderProvider.notifier)
        .set(
          FolderLocation(
            sourceId: location.sourceId,
            sourceName: location.sourceName,
            path: path,
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
          : () async {
              final ok = await ref
                  .read(playerActionsProvider)
                  .playFolder(location.sourceId, location.path);
              if (!ok && context.mounted) {
                ScaffoldMessenger.maybeOf(context)
                    ?.showSnackBar(const SnackBar(content: Text('无法播放这个文件夹')));
              }
            },
      icon: const Icon(Icons.play_arrow_rounded),
      label: const Text('播放文件夹'),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.icon,
    required this.name,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String name;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
                  '$count 首',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: LekisText.tabularFigures,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: colors.onSurfaceVariant,
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
            '这个文件夹没有直属曲目',
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
            '读取文件夹失败',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.danger),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('重试')),
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
            '选择一个音源，按文件夹浏览',
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
