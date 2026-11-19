// 音源状态的小部件：可达性圆点、扫描进度、状态文字。

import 'package:material_ui/material_ui.dart';

import '../../../rust/api/dto.dart';
import '../../../theme/tokens.dart';
import '../sources_providers.dart';
import '../strings.dart';

String scanPhaseLabel(ScanPhaseDto? phase) => switch (phase) {
  null => SourcesStrings.scanStarting,
  ScanPhaseDto.walking => SourcesStrings.phaseWalking,
  ScanPhaseDto.readingTags => SourcesStrings.phaseReadingTags,
  ScanPhaseDto.artwork => SourcesStrings.phaseArtwork,
  ScanPhaseDto.writingSharedIndex => SourcesStrings.phaseWritingSharedIndex,
};

String relativeTime(DateTime at) {
  final diff = DateTime.now().difference(at);
  if (diff.inMinutes < 1) return SourcesStrings.justNow;
  if (diff.inHours < 1) return SourcesStrings.minutesAgo(diff.inMinutes);
  return SourcesStrings.hoursAgo(diff.inHours);
}

String reachabilityLabel(SourceConfigDto source, SourceRuntime runtime) {
  if (!source.enabled) return SourcesStrings.disabled;
  return switch (runtime.reachable) {
    true => SourcesStrings.reachable,
    false => SourcesStrings.unreachable,
    null => SourcesStrings.reachabilityUnknown,
  };
}

String lastScanLabel(SourceRuntime runtime) {
  final last = runtime.lastScan;
  if (last == null) return SourcesStrings.neverScanned;
  return SourcesStrings.lastScan(
    relativeTime(last.finishedAt),
    last.added,
    last.updated,
    last.removed,
  );
}

/// 可达性小圆点（颜色之外还配了文字，色弱用户也能分辨）。
class ReachabilityDot extends StatelessWidget {
  const ReachabilityDot({super.key, required this.reachable});

  final bool? reachable;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final color = switch (reachable) {
      true => colors.accent,
      false => colors.danger,
      null => colors.outline,
    };
    return Container(
      width: LekisSpacing.sm,
      height: LekisSpacing.sm,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 扫描进度：阶段 + 进度条 + 已处理 / 总数。
class ScanProgressView extends StatelessWidget {
  const ScanProgressView({
    super.key,
    required this.runtime,
    this.dense = false,
  });

  final SourceRuntime runtime;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final style = dense
        ? theme.textTheme.bodySmall
        : theme.textTheme.bodyMedium;
    final count = runtime.phase == null
        ? ''
        : SourcesStrings.scanCount(runtime.done, runtime.total);
    return Semantics(
      liveRegion: true,
      label: '${scanPhaseLabel(runtime.phase)} $count',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  scanPhaseLabel(runtime.phase),
                  style: style?.copyWith(color: colors.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (count.isNotEmpty)
                Text(
                  count,
                  style: style?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
          const SizedBox(height: LekisSpacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(LekisRadius.pill),
            child: LinearProgressIndicator(
              value: runtime.fraction,
              color: colors.accent,
              backgroundColor: colors.accentSoft,
            ),
          ),
        ],
      ),
    );
  }
}

/// 音源类型图标（带浅色底）。
class SourceKindBadge extends StatelessWidget {
  const SourceKindBadge({super.key, required this.icon, this.size});

  final IconData icon;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final side = size ?? LekisSizes.listArtwork;
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(LekisRadius.artworkList),
      ),
      child: Icon(icon, color: colors.accent),
    );
  }
}
