// 补全确认页：自动找到但把握不大的封面 / 歌词 / 标签，在这里逐条确认；
// 同时提供「补全封面 / 歌词」入口，支持选择仅补全封面、仅补全歌词或全部补全。

import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../theme/tokens.dart';
import '../library/widgets/empty_state.dart';
import '../settings/widgets/settings_widgets.dart';
import '../sources/common.dart';
import 'enrich_actions.dart';
import 'enrich_progress.dart';
import 'enrich_providers.dart';
import 'strings.dart';
import 'widgets/candidate_card.dart';

class EnrichReviewPage extends ConsumerWidget {
  const EnrichReviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    context.l10n;
    final queue = ref.watch(enrichQueueProvider);
    final count = ref.watch(enrichPendingCountProvider) ?? queue.value?.length;
    final hasItems = (queue.value?.isNotEmpty ?? false);

    return SettingsScaffold(
      title: count == null || count == 0
          ? EnrichStrings.title
          : EnrichStrings.titleWithCount(count),
      actions: [
        OutlinedButton.icon(
          key: const ValueKey('enrich.start-batch'),
          onPressed: () => enrichMissingFromLibraryFlow(context),
          icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
          label: Text(EnrichActionStrings.action),
        ),
        if (hasItems) ...[
          const SizedBox(width: LekisSpacing.xs),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, LekisSizes.touchTargetMin),
            ),
            onPressed: () => _acceptAll(context, ref, count ?? 0),
            icon: const Icon(Icons.done_all),
            label: Text(EnrichStrings.acceptAll),
          ),
        ],
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const EnrichProgressBanner(showReviewAction: false),
          Expanded(
            child: queue.when(
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => LekisEmptyState(
                title: EnrichStrings.loadFailed,
                message: describeCoreError(e),
                action: TextButton.icon(
                  onPressed: () =>
                      ref.read(enrichQueueProvider.notifier).reload(),
                  icon: const Icon(Icons.refresh),
                  label: Text(EnrichStrings.retry),
                ),
              ),
              data: (list) => list.isEmpty
                  ? LekisEmptyState(
                      title: EnrichStrings.emptyTitle,
                      message: EnrichStrings.emptyBody,
                      action: FilledButton.tonalIcon(
                        onPressed: () => enrichMissingFromLibraryFlow(context),
                        icon: const Icon(Icons.auto_fix_high_outlined),
                        label: Text(EnrichActionStrings.action),
                      ),
                    )
                  : SettingsScrollView(
                      slivers: [
                        SliverList.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: LekisSpacing.md),
                          itemBuilder: (_, i) => CandidateCard(
                            key: ValueKey(list[i].id),
                            candidate: list[i],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _acceptAll(BuildContext context, WidgetRef ref, int n) async {
    final ok = await showLekisPanel<bool>(
      context,
      builder: (context) => LekisPanel(
        title: EnrichStrings.acceptAllConfirmTitle,
        body: Text(EnrichStrings.acceptAllConfirmBody(n)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(EnrichStrings.cancel),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(EnrichStrings.confirm),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final applied = await ref.read(enrichQueueProvider.notifier).acceptAll();
      if (context.mounted) {
        showFeatureSnack(context, EnrichStrings.acceptedAll(applied));
      }
    } catch (e) {
      if (context.mounted) showFeatureSnack(context, describeCoreError(e));
    }
  }
}
