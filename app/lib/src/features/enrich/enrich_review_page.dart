// 补全确认页：自动找到但把握不大的封面 / 歌词 / 标签，在这里逐条确认。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/tokens.dart';
import '../sources/common.dart';
import 'enrich_providers.dart';
import 'strings.dart';
import 'widgets/candidate_card.dart';

class EnrichReviewPage extends ConsumerWidget {
  const EnrichReviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(enrichQueueProvider);
    final count = ref.watch(enrichPendingCountProvider) ?? queue.value?.length;
    final hasItems = (queue.value?.isNotEmpty ?? false);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          count == null || count == 0
              ? EnrichStrings.title
              : EnrichStrings.titleWithCount(count),
        ),
        actions: [
          if (hasItems)
            Padding(
              padding: EdgeInsets.only(right: context.featureGutter),
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, LekisSizes.touchTargetMin),
                ),
                onPressed: () => _acceptAll(context, ref, count ?? 0),
                icon: const Icon(Icons.done_all),
                label: const Text(EnrichStrings.acceptAll),
              ),
            ),
        ],
      ),
      body: queue.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Empty(
          icon: Icons.error_outline,
          title: EnrichStrings.loadFailed,
          body: describeCoreError(e),
          action: TextButton.icon(
            onPressed: () => ref.read(enrichQueueProvider.notifier).reload(),
            icon: const Icon(Icons.refresh),
            label: const Text(EnrichStrings.retry),
          ),
        ),
        data: (list) => list.isEmpty
            ? const _Empty(
                icon: Icons.task_alt,
                title: EnrichStrings.emptyTitle,
                body: EnrichStrings.emptyBody,
              )
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: featureMaxContentWidth,
                  ),
                  child: ListView.builder(
                    padding: EdgeInsets.all(context.featureGutter),
                    itemCount: list.length,
                    itemBuilder: (_, i) => CandidateCard(
                      key: ValueKey(list[i].id),
                      candidate: list[i],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _acceptAll(BuildContext context, WidgetRef ref, int n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(EnrichStrings.acceptAllConfirmTitle),
        content: Text(EnrichStrings.acceptAllConfirmBody(n)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(EnrichStrings.cancel),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(EnrichStrings.confirm),
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

class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(context.featureGutter),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: featureMaxContentWidth / 2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: LekisSizes.listArtwork, color: colors.accent),
              const SizedBox(height: LekisSpacing.lg),
              Text(
                title,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: LekisSpacing.sm),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: LekisSpacing.lg),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
