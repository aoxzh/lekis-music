// Reusable loved / rating controls.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

void _showActionFailure(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// 心形收藏按钮：先本地变红，失败回滚。
class LovedButton extends ConsumerWidget {
  const LovedButton({
    super.key,
    required this.trackId,
    required this.initialLoved,
    this.size = 20,
    this.compact = true,
  });

  final int trackId;
  final bool initialLoved;
  final double size;

  /// 行内紧凑模式（36×36 触摸区）；Now Playing 用非紧凑模式。
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final loved =
        ref.watch(lovedOverridesProvider.select((m) => m[trackId])) ??
        initialLoved;
    return IconButton(
      tooltip: loved ? '取消喜欢' : '喜欢',
      visualDensity: VisualDensity.compact,
      constraints: compact
          ? const BoxConstraints.tightFor(width: 36, height: 36)
          : const BoxConstraints(
              minWidth: LekisSizes.touchTargetMin,
              minHeight: LekisSizes.touchTargetMin,
            ),
      padding: EdgeInsets.zero,
      onPressed: () async {
        final ok = await ref
            .read(libraryActionsProvider)
            .setLoved(trackId, !loved);
        if (!ok && context.mounted) {
          _showActionFailure(context, '更新收藏失败，请稍后再试');
        }
      },
      icon: Icon(
        loved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        size: size,
        color: loved ? colors.accent : colors.onSurfaceVariant,
      ),
    );
  }
}

/// 0~5 星评分。点击当前星级会清除评分。
class RatingStars extends ConsumerWidget {
  const RatingStars({
    super.key,
    required this.trackId,
    required this.initialRating,
    this.size = 20,
    this.compact = true,
  });

  final int trackId;
  final int? initialRating;
  final double size;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final rating = ratingOf(ref, trackId, initialRating) ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var star = 1; star <= 5; star++)
          IconButton(
            tooltip: star == rating ? '清除评分' : '$star 星',
            visualDensity: VisualDensity.compact,
            constraints: compact
                ? const BoxConstraints.tightFor(width: 30, height: 30)
                : const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            onPressed: () async {
              final next = star == rating ? null : star;
              final ok = await ref
                  .read(libraryActionsProvider)
                  .setRating(trackId, next);
              if (!ok && context.mounted) {
                _showActionFailure(context, '更新评分失败，请稍后再试');
              }
            },
            icon: Icon(
              star <= rating ? Icons.star_rounded : Icons.star_border_rounded,
              size: size,
              color: star <= rating
                  ? colors.accent
                  : colors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
      ],
    );
  }
}

/// 从曲目行菜单打开评分面板。
Future<void> showTrackRatingSheet(
  BuildContext context, {
  required int trackId,
  String? title,
}) => showLekisSheet<void>(
  context,
  // Content-sized: the sheet hugs the title line and the stars.
  heightFactor: null,
  builder: (_) => _RatingSheet(trackId: trackId, title: title),
);

class _RatingSheet extends ConsumerStatefulWidget {
  const _RatingSheet({required this.trackId, this.title});

  final int trackId;
  final String? title;

  @override
  ConsumerState<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends ConsumerState<_RatingSheet> {
  late Future<TrackDto> _future;

  @override
  void initState() {
    super.initState();
    _future = core.getTrack(trackId: widget.trackId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return FutureBuilder<TrackDto>(
      future: _future,
      builder: (context, snapshot) => Padding(
        padding: const EdgeInsets.fromLTRB(
          LekisSpacing.xl,
          0,
          LekisSpacing.xl,
          LekisSpacing.xxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('评分', style: theme.textTheme.titleLarge),
            const SizedBox(height: LekisSpacing.xs),
            if (widget.title != null)
              Text(
                widget.title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: LekisSpacing.lg),
            if (snapshot.connectionState == ConnectionState.waiting)
              // The sheet sizes to its content, so keep the loading state at
              // the height of the star row instead of filling the window.
              const SizedBox(
                height: LekisSizes.touchTargetMin,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (snapshot.hasError)
              Text(
                '加载失败：${describeCoreError(snapshot.error!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              )
            else
              RatingStars(
                trackId: widget.trackId,
                initialRating: snapshot.data!.rating?.toInt(),
                size: 32,
                compact: false,
              ),
          ],
        ),
      ),
    );
  }
}
