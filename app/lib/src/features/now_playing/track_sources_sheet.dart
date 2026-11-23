// Every copy of a track: local file, NAS share, media server or plugin.
// Opened from Now Playing's “more” menu and useful when the same song exists
// in several qualities / locations.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

Future<void> showTrackSourcesSheet(
  BuildContext context, {
  required int trackId,
  required String title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _TrackSourcesSheet(trackId: trackId, title: title),
  );
}

class _TrackSourcesSheet extends ConsumerStatefulWidget {
  const _TrackSourcesSheet({required this.trackId, required this.title});

  final int trackId;
  final String title;

  @override
  ConsumerState<_TrackSourcesSheet> createState() => _TrackSourcesSheetState();
}

class _TrackSourcesSheetState extends ConsumerState<_TrackSourcesSheet> {
  late Future<List<TrackSourceInfoDto>> _future;

  @override
  void initState() {
    super.initState();
    _future = core.trackSources(trackId: widget.trackId);
  }

  void _retry() {
    setState(() => _future = core.trackSources(trackId: widget.trackId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final l10n = context.l10n;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.65,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LekisSpacing.lg,
                0,
                LekisSpacing.lg,
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
                    widget.title,
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
              child: FutureBuilder<List<TrackSourceInfoDto>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(LekisSpacing.xl),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              color: colors.danger,
                            ),
                            const SizedBox(height: LekisSpacing.sm),
                            Text(
                              l10n.pick(
                                '读取来源失败：${snapshot.error}',
                                'Failed to load sources: ${snapshot.error}',
                              ),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: LekisSpacing.md),
                            OutlinedButton(
                              onPressed: _retry,
                              child: Text(l10n.pick('重试', 'Retry')),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  final sources = snapshot.data ?? const [];
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
        ),
      ),
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
      leading: Icon(Icons.storage_rounded, color: colors.onSurfaceVariant),
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
        '${source.sourceKind.name} · $details\n${source.path}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      isThreeLine: true,
      trailing: Icon(reachIcon, size: 20, color: reachColor),
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
