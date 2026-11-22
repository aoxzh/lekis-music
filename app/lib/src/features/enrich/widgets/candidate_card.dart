// 一条待确认候选：当前 vs 建议的对比 + 接受 / 拒绝。

import 'dart:io' show File;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../rust/api/dto.dart';
import '../../../theme/tokens.dart';
import '../../settings/widgets/settings_widgets.dart';
import '../../sources/common.dart';
import '../enrich_models.dart';
import '../enrich_providers.dart';
import '../strings.dart';

class CandidateCard extends ConsumerWidget {
  const CandidateCard({super.key, required this.candidate});

  final EnrichCandidateDto candidate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final current = ref.watch(candidateCurrentProvider(candidate));
    final proposal = parseProposal(candidate);
    final track = current.value?.track;
    final percent = (candidate.score * 100).round();

    return DecoratedBox(
      decoration: settingsPanelDecoration(context),
      child: Padding(
        padding: const EdgeInsets.all(LekisSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _KindChip(label: kindLabel(candidate.kind)),
                const SizedBox(width: LekisSpacing.sm),
                Expanded(
                  child: Text(
                    track == null
                        ? EnrichStrings.unknownTrack
                        : '${track.title} · ${track.artists.join(EnrichStrings.listSeparator)}',
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: LekisSpacing.xs),
            Text(
              '${EnrichStrings.fromSource(candidate.source)} · ${EnrichStrings.score(percent)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: LekisSpacing.lg),
            switch (proposal) {
              ArtworkProposal() => _ArtworkCompare(
                currentFile: current.value?.artworkFile,
                proposal: proposal,
              ),
              LyricsProposal() => _LyricsCompare(
                current: current.value?.lyrics,
                proposal: proposal,
              ),
              TagsProposal() => _TagDiff(changes: diffTags(track, proposal)),
              UnknownProposal() => Text(
                EnrichStrings.unreadablePayload,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            },
            const SizedBox(height: LekisSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, LekisSizes.touchTargetMin),
                  ),
                  onPressed: () => _act(context, ref, accept: false),
                  icon: const Icon(Icons.close),
                  label: Text(EnrichStrings.reject),
                ),
                const SizedBox(width: LekisSpacing.sm),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, LekisSizes.touchTargetMin),
                  ),
                  onPressed: proposal is UnknownProposal
                      ? null
                      : () => _act(context, ref, accept: true),
                  icon: const Icon(Icons.check),
                  label: Text(EnrichStrings.accept),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _act(
    BuildContext context,
    WidgetRef ref, {
    required bool accept,
  }) async {
    final queue = ref.read(enrichQueueProvider.notifier);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (accept) {
        await queue.accept(candidate);
      } else {
        await queue.reject(candidate);
      }
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              accept ? EnrichStrings.accepted : EnrichStrings.rejected,
            ),
            duration: LekisMotion.slow * 5,
          ),
        );
    } catch (e) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeCoreError(e))));
    }
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.sm,
        vertical: LekisSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(LekisRadius.pill),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: colors.accent),
      ),
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled({required this.label, required this.child, this.caption});

  final String label;
  final String? caption;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final style = theme.textTheme.labelMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: style),
        const SizedBox(height: LekisSpacing.xs),
        child,
        if (caption != null) ...[
          const SizedBox(height: LekisSpacing.xs),
          Text(caption!, style: style),
        ],
      ],
    );
  }
}

/// 缩略图边长：列表封面的两倍。
const double _thumb = LekisSizes.listArtwork * 2;

/// 封面预览 HTTP 请求头：网易云 126.net CDN 会对 Flutter 默认 `Dart/*` UA 返回 403。
Map<String, String> _artworkHeaders(String url) {
  final lower = url.toLowerCase();
  if (lower.contains('music.126.net') || lower.contains('music.163.com')) {
    return const {
      'User-Agent': 'Lekis/0.1',
      'Referer': 'https://music.163.com/',
    };
  }
  return const {'User-Agent': 'Lekis/0.1'};
}

class _ArtworkCompare extends StatelessWidget {
  const _ArtworkCompare({required this.currentFile, required this.proposal});

  final String? currentFile;
  final ArtworkProposal proposal;

  @override
  Widget build(BuildContext context) {
    final w = proposal.width;
    final h = proposal.height;
    final file = currentFile;
    return Wrap(
      spacing: LekisSpacing.xl,
      runSpacing: LekisSpacing.md,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Labeled(
          label: EnrichStrings.current,
          child: _Thumb(
            image: file == null ? null : FileImage(File(file)),
            emptyIcon: Icons.album_outlined,
          ),
        ),
        Icon(Icons.arrow_forward, color: context.lekisColors.onSurfaceVariant),
        _Labeled(
          label: EnrichStrings.proposed,
          caption: w != null && h != null
              ? EnrichStrings.dimensions(w, h)
              : null,
          child: _Thumb(
            image: NetworkImage(
              proposal.url,
              headers: _artworkHeaders(proposal.url),
            ),
            emptyIcon: Icons.cloud_off_outlined,
          ),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.image,
    this.emptyIcon = Icons.image_not_supported_outlined,
  });
  final ImageProvider? image;
  final IconData emptyIcon;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    Widget box(IconData icon) => ColoredBox(
      color: colors.surfaceVariant,
      child: Center(child: Icon(icon, color: colors.onSurfaceVariant)),
    );
    final img = image;
    return ClipRRect(
      borderRadius: BorderRadius.circular(LekisRadius.artworkGrid),
      child: SizedBox.square(
        dimension: _thumb,
        child: img == null
            ? box(emptyIcon)
            : Image(
                image: img,
                fit: BoxFit.cover,
                semanticLabel: EnrichStrings.kindArtwork,
                errorBuilder: (_, _, _) => box(Icons.cloud_off_outlined),
                frameBuilder: (_, child, frame, sync) => sync || frame != null
                    ? child
                    : ColoredBox(color: colors.surfaceVariant),
              ),
      ),
    );
  }
}

class _LyricsCompare extends StatelessWidget {
  const _LyricsCompare({required this.current, required this.proposal});

  final String? current;
  final LyricsProposal proposal;

  @override
  Widget build(BuildContext context) {
    final cur = current;
    final left = _LyricsBox(
      label: EnrichStrings.current,
      text: cur == null || cur.isEmpty
          ? EnrichStrings.none
          : lyricsPreview(cur),
    );
    final right = _LyricsBox(
      label: EnrichStrings.proposed,
      text: lyricsPreview(proposal.content),
    );
    if (context.isCompactWidth) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          left,
          const SizedBox(height: LekisSpacing.md),
          right,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: LekisSpacing.lg),
        Expanded(child: right),
      ],
    );
  }
}

class _LyricsBox extends StatelessWidget {
  const _LyricsBox({required this.label, required this.text});
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return _Labeled(
      label: label,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(LekisSpacing.md),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(LekisRadius.sm),
        ),
        child: Text(
          text,
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

class _TagDiff extends StatelessWidget {
  const _TagDiff({required this.changes});
  final List<TagChange> changes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Table(
      columnWidths: const {
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
        2: IntrinsicColumnWidth(),
        3: FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (final c in changes)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  right: LekisSpacing.md,
                  bottom: LekisSpacing.sm,
                ),
                child: Text(c.field.label, style: muted),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: LekisSpacing.sm),
                child: Text(
                  c.current.isEmpty ? EnrichStrings.none : c.current,
                  style: c.changed
                      ? muted?.copyWith(decoration: TextDecoration.lineThrough)
                      : muted,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm)
                    .copyWith(bottom: LekisSpacing.sm),
                child: Icon(
                  Icons.arrow_forward,
                  size: LekisSpacing.lg,
                  color: colors.onSurfaceVariant,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: LekisSpacing.sm),
                child: Text(
                  c.proposed,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: c.changed ? colors.accent : null,
                    fontWeight: c.changed ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
