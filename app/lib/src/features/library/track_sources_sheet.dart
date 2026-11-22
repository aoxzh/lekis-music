// 统一资料库（SRC-13）：查看曲目的全部来源与当前选源状态，以及手动合并 / 拆分。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';
import '../../theme/tokens.dart';
import '../../widgets/adaptive_panel.dart';
import '../downloads/downloads_models.dart' show formatBytes;
import '../sources/common.dart' show describeCoreError, showFeatureSnack;
import '../sources/source_kind_info.dart';

abstract final class UnifiedStrings {
  static String get menuTitle => L10n.tr('来源与音质', 'Sources & Quality');
  static String get sheetTitle => L10n.tr('曲目来源', 'Track Sources');
  static String get preferred => L10n.tr('当前首选', 'Preferred');
  static String get unreachable => L10n.tr('当前不可达', 'Unreachable');
  static String get splitAction => L10n.tr('拆分', 'Split');
  static String get splitTooltip => L10n.tr('拆分为独立曲目', 'Split into separate track');
  static String get splitDone => L10n.tr('已拆分为独立曲目', 'Split into a separate track');
  static String get mergeAction => L10n.tr('合并为同一首歌', 'Merge as Same Track');
  static String get alreadyMerged => L10n.tr('已合并为同一首歌', 'Already Unified');
  static String get deleteLowerQuality =>
      L10n.tr('删除低音质版本', 'Delete Lower-Quality');
  static String get deleteThisCopy => L10n.tr('删除此低音质版本', 'Delete this copy');
  static String get deleteConfirmTitle =>
      L10n.tr('删除低音质版本？', 'Delete Lower-Quality Copies?');
  static String get deleteDiskToggle =>
      L10n.tr('同时删除磁盘 / NAS 上的源文件', 'Also delete files from disk / NAS');
  static String get deleteDiskHint => L10n.tr(
    '勾选后将永久删除源文件且无法撤销；取消勾选则仅从资料库移除索引。',
    'Permanent and cannot be undone; uncheck to remove from library index only.',
  );
  static String get deleteConfirmBtn => L10n.tr('确认删除', 'Delete');
  static String deleteDone(int count, String freed, {required bool disk}) =>
      disk
          ? L10n.tr(
              '已删除 $count 个低音质文件（释放 $freed）',
              'Deleted $count lower-quality files ($freed freed)',
            )
          : L10n.tr(
              '已从资料库移除 $count 个低音质副本（保留磁盘文件）',
              'Removed $count lower-quality copies from library (files kept)',
            );
  static String mergeDone(int count) => L10n.tr(
    '已合并 $count 个版本为同一首歌（不删磁盘文件）',
    'Merged $count versions into one track (files kept on disk)',
  );
  static String get empty => L10n.tr('没有找到这首歌的来源文件', 'No source files found');
  static String get multiSourceHint => L10n.tr(
    '播放时按「可用性 > 就近程度 > 音质」自动选源；若误把两首不同的歌合到一起，可点右侧「拆分」。',
    'Playback auto-picks by availability > locality > quality; tap Split if two different songs were merged.',
  );
}

/// 供 UI 与单测注入的统一资料库操作入口。
abstract interface class UnifiedLibraryGateway {
  Future<List<TrackSourceInfoDto>> trackSources(int trackId);
  Future<int> mergeTracks(int keepId, List<int> absorbIds);
  Future<int> splitTrackSource({
    required int trackId,
    required int sourceId,
    int? fileId,
    String? externalId,
  });
  Future<bool> deleteDuplicateFile({
    required int sourceId,
    required String path,
    required bool deleteSourceFile,
  });
}

class _CoreUnifiedLibraryGateway implements UnifiedLibraryGateway {
  const _CoreUnifiedLibraryGateway();

  @override
  Future<List<TrackSourceInfoDto>> trackSources(int trackId) =>
      core.trackSources(trackId: trackId);

  @override
  Future<int> mergeTracks(int keepId, List<int> absorbIds) async =>
      (await core.mergeTracks(
        keepId: keepId,
        absorbIds: Int64List.fromList(absorbIds),
      )).toInt();

  @override
  Future<int> splitTrackSource({
    required int trackId,
    required int sourceId,
    int? fileId,
    String? externalId,
  }) => core.splitTrackSource(
    trackId: trackId,
    sourceId: sourceId,
    fileId: fileId,
    externalId: externalId,
  );

  @override
  Future<bool> deleteDuplicateFile({
    required int sourceId,
    required String path,
    required bool deleteSourceFile,
  }) => core.deleteDuplicateFile(
    sourceId: sourceId,
    path: path,
    deleteSourceFile: deleteSourceFile,
  );
}

final unifiedLibraryGatewayProvider = Provider<UnifiedLibraryGateway>(
  (_) => const _CoreUnifiedLibraryGateway(),
);

final trackSourcesProvider = FutureProvider.autoDispose
    .family<List<TrackSourceInfoDto>, int>(
      (ref, trackId) =>
          ref.watch(unifiedLibraryGatewayProvider).trackSources(trackId),
    );

/// 打开曲目的来源与选源状态面板（桌面弹窗 / 手机底部表）。
Future<void> showTrackSourcesSheet(
  BuildContext context, {
  required int trackId,
  required String trackTitle,
}) => showLekisSheet<void>(
  context,
  heightFactor: 0.56,
  builder: (_) => TrackSourcesView(trackId: trackId, trackTitle: trackTitle),
);

class TrackSourcesView extends ConsumerStatefulWidget {
  const TrackSourcesView({
    super.key,
    required this.trackId,
    required this.trackTitle,
  });

  final int trackId;
  final String trackTitle;

  @override
  ConsumerState<TrackSourcesView> createState() => _TrackSourcesViewState();
}

class _TrackSourcesViewState extends ConsumerState<TrackSourcesView> {
  bool _busy = false;

  Future<void> _split(TrackSourceInfoDto entry) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(unifiedLibraryGatewayProvider)
          .splitTrackSource(
            trackId: widget.trackId,
            sourceId: entry.sourceId,
            fileId: entry.fileId,
            externalId: entry.externalId,
          );
      ref.invalidate(trackSourcesProvider(widget.trackId));
      if (mounted) showFeatureSnack(context, UnifiedStrings.splitDone);
    } catch (e) {
      if (mounted) {
        showFeatureSnack(context, describeCoreError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncSources = ref.watch(trackSourcesProvider(widget.trackId));
    final theme = Theme.of(context);
    final colors = context.lekisColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LekisSpacing.xl,
            0,
            LekisSpacing.xl,
            LekisSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                UnifiedStrings.sheetTitle,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: LekisSpacing.xxs),
              Text(
                widget.trackTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: asyncSources.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(LekisSpacing.xl),
                child: Text(
                  describeCoreError(e),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.danger,
                  ),
                ),
              ),
            ),
            data: (entries) {
              if (entries.isEmpty) {
                return Center(
                  child: Text(
                    UnifiedStrings.empty,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                );
              }
              final canSplit = entries.length > 1;
              return ListView.separated(
                padding: const EdgeInsets.all(LekisSpacing.lg),
                itemCount: entries.length + (canSplit ? 1 : 0),
                separatorBuilder: (_, _) =>
                    const SizedBox(height: LekisSpacing.sm),
                itemBuilder: (context, index) {
                  if (index == entries.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: LekisSpacing.xs),
                      child: Text(
                        UnifiedStrings.multiSourceHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  final entry = entries[index];
                  final detailParts = <String>[
                    entry.sourceKind.label,
                    if (entry.format != null && entry.format!.isNotEmpty)
                      entry.format!,
                    if (entry.sizeBytes > BigInt.zero)
                      formatBytes(entry.sizeBytes.toInt()),
                    if (entry.reachable == false) UnifiedStrings.unreachable,
                  ];
                  final location = entry.path.isNotEmpty
                      ? entry.path
                      : (entry.externalId ?? '');
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: entry.preferred
                          ? colors.accentSoft.withValues(alpha: 0.55)
                          : colors.surfaceVariant,
                      borderRadius: BorderRadius.circular(LekisRadius.md),
                      border: Border.all(
                        color: entry.preferred ? colors.accent : colors.outline,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(LekisSpacing.md),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            entry.sourceKind.icon,
                            color: entry.preferred
                                ? colors.accent
                                : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: LekisSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        entry.sourceName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleSmall,
                                      ),
                                    ),
                                    if (entry.preferred) ...[
                                      const SizedBox(width: LekisSpacing.sm),
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: colors.accent,
                                          borderRadius: BorderRadius.circular(
                                            LekisRadius.pill,
                                          ),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: LekisSpacing.sm,
                                            vertical: 2,
                                          ),
                                          child: Text(
                                            UnifiedStrings.preferred,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color: colors.onAccent,
                                                ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: LekisSpacing.xxs),
                                Text(
                                  detailParts.join(' · '),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: entry.reachable == false
                                        ? colors.danger
                                        : colors.onSurfaceVariant,
                                  ),
                                ),
                                if (location.isNotEmpty) ...[
                                  const SizedBox(height: LekisSpacing.xxs),
                                  Text(
                                    location,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (canSplit)
                            TextButton(
                              key: ValueKey('track-source.split.$index'),
                              onPressed: _busy ? null : () => _split(entry),
                              child: Text(UnifiedStrings.splitAction),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
