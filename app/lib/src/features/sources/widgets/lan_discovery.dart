// 「在你的网络上发现」：打开添加音源时自动扫描，结果放在本地文件夹下面。
//
// 结果只来自核心的真实发现。SMB / WebDAV 点一下会带着地址进入表单；
// DLNA 只作为「这台机器可能有 SMB 共享」的提示。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../rust/api/dto.dart';
import '../../../theme/tokens.dart';
import '../common.dart';
import '../discovered_service_info.dart';
import '../discovery_providers.dart';
import '../strings.dart';
import 'source_status.dart';

class LanDiscoverySection extends ConsumerStatefulWidget {
  const LanDiscoverySection({super.key, required this.onPick});

  /// 用户点了一条发现结果。调用方决定打开哪种表单。
  final ValueChanged<DiscoveredServiceDto> onPick;

  @override
  ConsumerState<LanDiscoverySection> createState() =>
      _LanDiscoverySectionState();
}

class _LanDiscoverySectionState extends ConsumerState<LanDiscoverySection> {
  @override
  void initState() {
    super.initState();
    // 打开「添加音源」就开始扫，不用用户去找按钮。Android 的组播锁由
    // lanScannerProvider 在扫描期间持有。
    Future.microtask(() {
      if (mounted) ref.read(lanDiscoveryProvider.notifier).ensureScanned();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lanDiscoveryProvider);
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );

    return Column(
      key: const ValueKey('lan-discovery'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.wifi_find_outlined, color: colors.onSurfaceVariant),
            const SizedBox(width: LekisSpacing.md),
            Expanded(
              child: Text(
                SourcesStrings.discoveryTitle,
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (state.scanning)
              const Padding(
                padding: EdgeInsets.all(LekisSpacing.md),
                child: SizedBox.square(
                  dimension: LekisSpacing.lg,
                  child: CircularProgressIndicator(
                    strokeWidth: LekisSpacing.xxs,
                  ),
                ),
              )
            else
              IconButton(
                key: const ValueKey('lan-discovery-rescan'),
                tooltip: SourcesStrings.scanAgain,
                onPressed: () => ref.read(lanDiscoveryProvider.notifier).scan(),
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        if (state.scanning) ...[
          const SizedBox(height: LekisSpacing.xs),
          const LinearProgressIndicator(),
          const SizedBox(height: LekisSpacing.sm),
          Text(SourcesStrings.discoveryScanningBody, style: muted),
        ] else if (state.error != null) ...[
          const SizedBox(height: LekisSpacing.xs),
          Semantics(
            liveRegion: true,
            child: Text(
              '${SourcesStrings.discoveryError}：${describeCoreError(state.error!)}',
              style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ),
        ] else if (state.isEmpty) ...[
          const SizedBox(height: LekisSpacing.xs),
          Text(SourcesStrings.discoveryNothingYet, style: muted),
        ] else if (state.results.isNotEmpty) ...[
          const SizedBox(height: LekisSpacing.xs),
          Text(
            '${SourcesStrings.discoveryFoundCount(state.results.length)} · '
            '${SourcesStrings.discoveryPickHint}',
            style: muted,
          ),
          const SizedBox(height: LekisSpacing.sm),
          for (final service in state.results)
            _DiscoveredTile(
              key: ValueKey(
                '${service.kind.name}:${service.host}:${service.port}:${service.path}',
              ),
              service: service,
              onTap: () => widget.onPick(service),
            ),
        ],
      ],
    );
  }
}

class _DiscoveredTile extends StatelessWidget {
  const _DiscoveredTile({
    super.key,
    required this.service,
    required this.onTap,
  });

  final DiscoveredServiceDto service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final note = service.note;
    return Card(
      elevation: 0,
      color: colors.surfaceVariant,
      margin: const EdgeInsets.only(bottom: LekisSpacing.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: LekisSizes.touchTargetMin + LekisSpacing.lg,
        leading: SourceKindBadge(icon: service.icon),
        title: Text(service.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: LekisSpacing.xxs),
            Text(
              '${service.kindLabel} · ${service.viaLabel}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            Text(
              service.addressLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (service.hostname != null && service.hostname != service.host)
              Text(
                service.hostname!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            if (note != null)
              Text(
                note,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.moon),
              ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
