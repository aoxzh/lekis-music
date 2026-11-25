// Every copy of a track: local file, NAS share, media server or plugin.
// Opened from Now Playing's “more” menu and useful when the same song exists
// in several qualities / locations.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/sources/sources_page.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/features/library/track_sources_sheet.dart'
    show trackSourcesProvider;
import 'package:lekis/src/features/sources/source_kind_info.dart';
import 'package:lekis/src/features/sources/common.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

Future<void> showTrackSourcesSheet(
  BuildContext context, {
  required int trackId,
  required String title,
}) {
  return showLekisSheet<void>(
    context,
    heightFactor: 0.65,
    builder: (_) => _TrackSourcesSheet(trackId: trackId, title: title),
  );
}

class _TrackSourcesSheet extends ConsumerWidget {
  const _TrackSourcesSheet({required this.trackId, required this.title});

  final int trackId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = trackSourcesProvider(trackId);
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LekisSpacing.xl,
            0,
            LekisSpacing.xl,
            LekisSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.pick('曲目来源', 'Track Sources'),
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: LekisSpacing.xxs),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.outline),
        Expanded(
          child: ref
              .watch(provider)
              .when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(LekisSpacing.xl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          describeCoreError(error),
                          textAlign: TextAlign.center,
                        ),
                        TextButton.icon(
                          onPressed: () => ref.invalidate(provider),
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(l10n.pick('重试', 'Retry')),
                        ),
                      ],
                    ),
                  ),
                ),
                data: (sources) {
                  if (sources.isEmpty) {
                    return Center(
                      child: Text(
                        l10n.pick('没有找到可播放的来源', 'No playable sources found'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      vertical: LekisSpacing.sm,
                    ),
                    itemCount: sources.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      indent: LekisSpacing.lg,
                      endIndent: LekisSpacing.lg,
                      color: colors.outline,
                    ),
                    itemBuilder: (context, index) =>
                        _SourceTile(source: sources[index], l10n: l10n),
                  );
                },
              ),
        ),
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.source, required this.l10n});

  final TrackSourceInfoDto source;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final reachable = source.reachable;
    final reachIcon = switch (reachable) {
      true => Icons.cloud_done_rounded,
      false => Icons.cloud_off_rounded,
      null => Icons.help_outline_rounded,
    };
    final reachColor = switch (reachable) {
      true => colors.accent,
      false => colors.danger,
      null => colors.onSurfaceVariant,
    };
    final format = source.format?.trim();
    final details = [
      if (format != null && format.isNotEmpty) format,
      _formatBytes(source.sizeBytes),
      'Q${source.qualityScore.toInt()}',
    ].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: LekisSpacing.xl),
      leading: Tooltip(
        message: switch (reachable) {
          true => l10n.pick('可连接', 'Reachable'),
          false => l10n.pick('无法连接', 'Unreachable'),
          null => l10n.pick('未检测', 'Not checked'),
        },
        child: Icon(reachIcon, color: reachColor),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              source.sourceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (source.preferred)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: LekisSpacing.xs),
              child: Text(
                l10n.pick('首选', 'Preferred'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        '${source.sourceKind.label} · $details\n${source.path}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      isThreeLine: true,
      onTap: () =>
          Navigator.of(context)
              .push(SourceDetailPage.route(source.sourceId.toInt())),
      trailing: IconButton(
        tooltip: l10n.pick('复制路径', 'Copy path'),
        iconSize: LekisSpacing.xl - LekisSpacing.xs,
        constraints: const BoxConstraints(
          minWidth: LekisSizes.touchTargetMin,
          minHeight: LekisSizes.touchTargetMin,
        ),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: source.path));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(content: Text(l10n.pick('已复制路径', 'Path copied'))),
            );
        },
        icon: const Icon(Icons.copy_rounded),
      ),
    );
  }
}

String _formatBytes(BigInt bytes) {
  final value = bytes.toInt();
  if (value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = value.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final digits = size >= 100 || unit == 0 ? 0 : 1;
  return '${size.toStringAsFixed(digits)} ${units[unit]}';
}
