// 下载状态的小控件和行内动作。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

void _showFailure(
  BuildContext context,
  String zhAction,
  String enAction,
  Object error,
) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.pick(
            '$zhAction失败：${describeCoreError(error)}',
            '$enAction failed: ${describeCoreError(error)}',
          ),
        ),
      ),
    );
}

Future<void> startDownload(
  BuildContext context,
  WidgetRef ref,
  int trackId,
) async {
  try {
    await ref.read(downloadsProvider.notifier).downloadTrack(trackId);
  } catch (e) {
    if (context.mounted) _showFailure(context, '下载', 'Download', e);
  }
}

Future<void> startDownloads(
  BuildContext context,
  WidgetRef ref,
  List<int> trackIds,
) async {
  if (trackIds.isEmpty) return;
  try {
    await ref.read(downloadsProvider.notifier).downloadTracks(trackIds);
  } catch (e) {
    if (context.mounted) _showFailure(context, '下载', 'Download', e);
  }
}

Future<void> removeDownload(
  BuildContext context,
  WidgetRef ref,
  int trackId,
) async {
  try {
    await ref.read(downloadsProvider.notifier).removeDownload(trackId);
  } catch (e) {
    if (context.mounted) _showFailure(context, '删除下载', 'Remove download', e);
  }
}

/// 曲目菜单里的下载动作文案。
String downloadMenuLabel(OfflineStateDto? state) => switch (state) {
  null => L10n.tr('下载', 'Download'),
  OfflineStateDto.queued => L10n.tr('开始下载', 'Start Download'),
  OfflineStateDto.downloading => L10n.tr('取消下载', 'Cancel Download'),
  OfflineStateDto.ready => L10n.tr('删除下载', 'Remove Download'),
  OfflineStateDto.failed => L10n.tr('重试下载', 'Retry Download'),
};

/// 执行菜单动作：未下载 / 失败 / 排队 → 开始；下载中 / 已下载 → 删除。
Future<void> runDownloadMenuAction(
  BuildContext context,
  WidgetRef ref,
  int trackId,
  OfflineStateDto? state,
) async {
  switch (state) {
    case null:
    case OfflineStateDto.failed:
    case OfflineStateDto.queued:
      await startDownload(context, ref, trackId);
    case OfflineStateDto.downloading:
    case OfflineStateDto.ready:
      await removeDownload(context, ref, trackId);
  }
}

/// 单曲离线状态角标：下载中显示 16×16 进度环，已离线缓存显示极光绿离线图标（OFF-01）；
/// 其他状态不占空间。
class CompactDownloadProgress extends ConsumerWidget {
  const CompactDownloadProgress({super.key, required this.trackId});

  final int trackId;

  static const Key downloadedIconKey = ValueKey(
    'compact-download.downloaded-icon',
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(downloadStateProvider(trackId));
    final colors = context.lekisColors;
    if (state == OfflineStateDto.ready) {
      return Padding(
        padding: const EdgeInsets.only(right: LekisSpacing.xs),
        child: Tooltip(
          message: l10n.pick('已离线缓存', 'Downloaded for offline'),
          child: Icon(
            Icons.offline_pin_rounded,
            key: downloadedIconKey,
            size: 16,
            color: colors.aurora,
          ),
        ),
      );
    }
    if (state != OfflineStateDto.downloading) return const SizedBox.shrink();
    final progress = ref.watch(downloadProgressProvider(trackId));
    return Padding(
      padding: const EdgeInsets.only(right: LekisSpacing.xs),
      child: Tooltip(
        message: progress == null
            ? l10n.pick('正在下载', 'Downloading')
            : l10n.pick(
                '正在下载 ${(progress * 100).round()}%',
                'Downloading ${(progress * 100).round()}%',
              ),
        child: SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(
            value: progress,
            strokeWidth: 2,
            color: colors.accent,
            backgroundColor: colors.outline.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}

/// 正在播放 / 曲目页用的下载按钮。
class TrackDownloadButton extends ConsumerWidget {
  const TrackDownloadButton({
    super.key,
    required this.trackId,
    this.compact = true,
  });

  final int trackId;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(downloadStateProvider(trackId));
    final progress = ref.watch(downloadProgressProvider(trackId));
    final colors = context.lekisColors;
    final constraints = compact
        ? const BoxConstraints.tightFor(width: 36, height: 36)
        : const BoxConstraints(
            minWidth: LekisSizes.touchTargetMin,
            minHeight: LekisSizes.touchTargetMin,
          );

    switch (state) {
      case null:
        return IconButton(
          tooltip: l10n.pick('下载', 'Download'),
          visualDensity: VisualDensity.compact,
          constraints: constraints,
          padding: EdgeInsets.zero,
          onPressed: () => startDownload(context, ref, trackId),
          icon: Icon(
            Icons.download_for_offline_outlined,
            size: 22,
            color: colors.onSurfaceVariant,
          ),
        );
      case OfflineStateDto.queued:
        return IconButton(
          tooltip: l10n.pick('开始下载', 'Start Download'),
          visualDensity: VisualDensity.compact,
          constraints: constraints,
          padding: EdgeInsets.zero,
          onPressed: () => startDownload(context, ref, trackId),
          icon: Icon(
            Icons.schedule_rounded,
            size: 22,
            color: colors.onSurfaceVariant,
          ),
        );
      case OfflineStateDto.downloading:
        return IconButton(
          tooltip: l10n.pick('取消下载', 'Cancel Download'),
          visualDensity: VisualDensity.compact,
          constraints: constraints,
          padding: EdgeInsets.zero,
          onPressed: () => removeDownload(context, ref, trackId),
          icon: SizedBox.square(
            dimension: 18,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2,
                  color: colors.accent,
                  backgroundColor: colors.outline.withValues(alpha: 0.35),
                ),
                Icon(Icons.close_rounded, size: 10, color: colors.accent),
              ],
            ),
          ),
        );
      case OfflineStateDto.ready:
        return IconButton(
          tooltip: l10n.pick('已下载', 'Downloaded'),
          visualDensity: VisualDensity.compact,
          constraints: constraints,
          padding: EdgeInsets.zero,
          onPressed: null,
          icon: const Icon(Icons.download_done_rounded, size: 22),
        );
      case OfflineStateDto.failed:
        return IconButton(
          tooltip: l10n.pick('重试下载', 'Retry Download'),
          visualDensity: VisualDensity.compact,
          constraints: constraints,
          padding: EdgeInsets.zero,
          onPressed: () => startDownload(context, ref, trackId),
          icon: Icon(Icons.refresh_rounded, size: 22, color: colors.danger),
        );
    }
  }
}

/// 专辑 / 多选下载按钮：全部完成时显示"已下载"，否则点击下载缺失的。
class BatchDownloadButton extends ConsumerWidget {
  const BatchDownloadButton({
    super.key,
    required this.trackIds,
    this.tooltip,
  });

  final List<int> trackIds;
  final String? tooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final downloads = ref.watch(downloadsProvider).value;
    final allReady =
        trackIds.isNotEmpty &&
        trackIds.every((id) => downloads?.entryFor(id)?.isReady ?? false);
    return IconButton(
      tooltip: allReady
          ? l10n.pick('已全部下载', 'All Downloaded')
          : (tooltip ?? l10n.pick('下载全部', 'Download All')),
      onPressed: allReady ? null : () => startDownloads(context, ref, trackIds),
      icon: Icon(
        allReady
            ? Icons.download_done_rounded
            : Icons.download_for_offline_outlined,
      ),
    );
  }
}
