// 资料库补全任务进度状态与进度条组件（资料库检查页 + 待确认页共用）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_actions.dart'
    show describeCoreError;
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

import 'enrich_actions.dart' show EnrichActionStrings, EnrichScope, enrichScopeSettingKey;

/// 待补全目标（曲目 ID + 可选展示标题）。
@immutable
class EnrichTarget {
  const EnrichTarget({required this.trackId, this.title});

  final int trackId;
  final String? title;
}

/// 一次批量补全任务的实时进度快照。
@immutable
class EnrichTaskProgress {
  const EnrichTaskProgress({
    required this.scope,
    required this.total,
    required this.completed,
    required this.autoApplied,
    required this.queued,
    required this.running,
    this.currentTitle,
    this.cancelled = false,
    this.error,
  });

  final EnrichScope scope;
  final int total;
  final int completed;
  final int autoApplied;
  final int queued;
  final bool running;
  final String? currentTitle;
  final bool cancelled;
  final String? error;

  double? get fraction =>
      total > 0 ? (completed / total).clamp(0.0, 1.0) : null;

  EnrichTaskProgress copyWith({
    int? completed,
    int? autoApplied,
    int? queued,
    bool? running,
    String? currentTitle,
    bool clearCurrentTitle = false,
    bool? cancelled,
    String? error,
  }) => EnrichTaskProgress(
    scope: scope,
    total: total,
    completed: completed ?? this.completed,
    autoApplied: autoApplied ?? this.autoApplied,
    queued: queued ?? this.queued,
    running: running ?? this.running,
    currentTitle: clearCurrentTitle
        ? null
        : (currentTitle ?? this.currentTitle),
    cancelled: cancelled ?? this.cancelled,
    error: error ?? this.error,
  );
}

final enrichProgressProvider =
    NotifierProvider<EnrichProgressNotifier, EnrichTaskProgress?>(
      EnrichProgressNotifier.new,
    );

class EnrichProgressNotifier extends Notifier<EnrichTaskProgress?> {
  bool _cancelRequested = false;

  @override
  EnrichTaskProgress? build() => null;

  void cancel() {
    if (state?.running != true) return;
    _cancelRequested = true;
    state = state!.copyWith(cancelled: true);
  }

  void dismiss() {
    if (state?.running == true) return;
    state = null;
  }

  /// 逐首执行补全并实时更新进度条；支持随时取消。
  Future<EnrichTaskProgress?> run({
    required EnrichScope scope,
    required List<EnrichTarget> targets,
    VoidCallback? onCompleted,
  }) async {
    if (targets.isEmpty) return null;
    if (state?.running == true) return state;

    _cancelRequested = false;
    state = EnrichTaskProgress(
      scope: scope,
      total: targets.length,
      completed: 0,
      autoApplied: 0,
      queued: 0,
      running: true,
      currentTitle: targets.first.title,
    );

    var completed = 0;
    var autoApplied = 0;
    var queued = 0;
    String? errorMessage;

    try {
      await core.setSetting(
        key: enrichScopeSettingKey,
        value: scope.storageValue,
      );
      for (final target in targets) {
        if (_cancelRequested) break;
        if (ref.mounted) {
          state = state?.copyWith(
            completed: completed,
            autoApplied: autoApplied,
            queued: queued,
            currentTitle: target.title,
          );
        }
        try {
          final report = await core.enrichTrack(trackId: target.trackId);
          autoApplied += report.autoApplied;
          queued += report.queued;
        } catch (e) {
          // 单首失败记录最近错误但不中断整批任务。
          errorMessage = describeCoreError(e);
        }
        completed += 1;
        if (ref.mounted) {
          state = state?.copyWith(
            completed: completed,
            autoApplied: autoApplied,
            queued: queued,
          );
        }
      }
    } catch (e) {
      errorMessage = describeCoreError(e);
    } finally {
      try {
        await core.setSetting(key: enrichScopeSettingKey, value: 'all');
      } catch (_) {}
    }

    if (ref.mounted) {
      state = state?.copyWith(
        completed: completed,
        autoApplied: autoApplied,
        queued: queued,
        running: false,
        cancelled: _cancelRequested,
        clearCurrentTitle: true,
        error: completed == 0 ? errorMessage : null,
      );
    }
    onCompleted?.call();
    return state;
  }
}

/// 补全进度条横幅：展示当前补全进度、已应用/待确认数，并支持取消或直接跳去确认。
class EnrichProgressBanner extends ConsumerWidget {
  const EnrichProgressBanner({super.key, this.showReviewAction = true});

  final bool showReviewAction;

  static const Key progressBarKey = ValueKey('enrich.progress-bar');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(enrichProgressProvider);
    if (progress == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final l10n = context.l10n;

    final String headline;
    if (progress.running) {
      final actionName = switch (progress.scope) {
        EnrichScope.all => l10n.pick('正在补全封面和歌词', 'Fetching artwork & lyrics'),
        EnrichScope.artwork => l10n.pick('正在补全缺失封面', 'Fetching missing covers'),
        EnrichScope.lyrics => l10n.pick('正在补全缺失歌词', 'Fetching missing lyrics'),
      };
      headline = '$actionName · ${progress.completed} / ${progress.total}';
    } else if (progress.cancelled) {
      headline = l10n.pick(
        '已取消补全（完成 ${progress.completed} / ${progress.total}）',
        'Enrichment cancelled (${progress.completed} / ${progress.total})',
      );
    } else if (progress.error != null) {
      headline = '${EnrichActionStrings.failed}：${progress.error}';
    } else {
      final summaryParts = [
        if (progress.autoApplied > 0)
          l10n.pick(
            '已自动补全 ${progress.autoApplied} 项',
            'Applied ${progress.autoApplied}',
          ),
        if (progress.queued > 0)
          l10n.pick('${progress.queued} 项待确认', '${progress.queued} to review'),
      ];
      headline = summaryParts.isEmpty
          ? l10n.pick(
              '补全完成（已检查 ${progress.completed} 项，暂未找到新结果）',
              'Done (${progress.completed} checked, no new matches)',
            )
          : l10n.pick(
              '补全完成：${summaryParts.join('，')}',
              'Done: ${summaryParts.join(', ')}',
            );
    }

    final String? detail;
    if (progress.running) {
      final bits = [
        if (progress.currentTitle != null &&
            progress.currentTitle!.trim().isNotEmpty)
          progress.currentTitle!.trim(),
        if (progress.autoApplied > 0)
          l10n.pick('已应用 ${progress.autoApplied}', 'Applied ${progress.autoApplied}'),
        if (progress.queued > 0)
          l10n.pick('待确认 ${progress.queued}', 'Review ${progress.queued}'),
      ];
      detail = bits.isEmpty ? null : bits.join(' · ');
    } else {
      detail = null;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LekisSpacing.lg,
        LekisSpacing.sm,
        LekisSpacing.lg,
        LekisSpacing.xs,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(LekisRadius.md),
          border: Border.all(
            color: progress.running
                ? colors.accent.withValues(alpha: 0.45)
                : colors.outline,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(LekisSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    progress.running
                        ? progress.scope.icon
                        : (progress.error != null
                              ? Icons.error_outline_rounded
                              : Icons.check_circle_outline_rounded),
                    size: 18,
                    color: progress.error != null
                        ? colors.danger
                        : colors.accent,
                  ),
                  const SizedBox(width: LekisSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          headline,
                          style: theme.textTheme.labelLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (detail != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            detail,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (progress.running)
                    TextButton(
                      onPressed: () =>
                          ref.read(enrichProgressProvider.notifier).cancel(),
                      child: Text(EnrichActionStrings.cancel),
                    )
                  else ...[
                    if (showReviewAction && progress.queued > 0)
                      TextButton(
                        onPressed: () => openEnrichReview(context),
                        child: Text(EnrichActionStrings.review),
                      ),
                    IconButton(
                      tooltip: l10n.pick('关闭', 'Dismiss'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          ref.read(enrichProgressProvider.notifier).dismiss(),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ],
                ],
              ),
              if (progress.running) ...[
                const SizedBox(height: LekisSpacing.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(LekisRadius.pill),
                  child: LinearProgressIndicator(
                    key: progressBarKey,
                    value: progress.fraction,
                    minHeight: 5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
