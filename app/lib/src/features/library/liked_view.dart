// "喜欢的歌曲" 视图：直接读核心的 loved_tracks，不建虚拟歌单。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/paged_track_list.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class LikedSongsView extends ConsumerWidget {
  const LikedSongsView({super.key});

  Future<void> _playAll(BuildContext context) async {
    try {
      await core.playContext(
        context: const PlayContextDto.loved(),
        startIndex: 0,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('播放失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final gutter = pageGutterOf(context);
    final count = ref.watch(lovedCountProvider).value;
    final list = ref.watch(likedTracksListProvider);

    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.md,
        gutter,
        LekisSpacing.md,
      ),
      child: Row(
        children: [
          Icon(Icons.favorite_rounded, color: colors.accent),
          const SizedBox(width: LekisSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    '喜欢的歌曲',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  count == null ? '正在统计…' : '$count 首',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: count == 0 ? null : () => _playAll(context),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('播放全部'),
          ),
        ],
      ),
    );

    return PagedTrackList(
      list: list,
      header: header,
      empty: const _EmptyLiked(),
    );
  }
}

class _EmptyLiked extends StatelessWidget {
  const _EmptyLiked();

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.favorite_border_rounded,
            size: LekisSpacing.xxxl,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Text(
            '还没有喜欢的歌曲',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: LekisSpacing.xxs),
          Text(
            '在歌曲行或正在播放里点一下心形',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
