// 「局域网里的设备」：扫描按钮 + 结果列表。
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

class LanDiscoverySection extends ConsumerWidget {
  const LanDiscoverySection({super.key, required this.onPick});

  /// 用户点了一条发现结果。调用方决定打开哪种表单。
  final ValueChanged<DiscoveredServiceDto> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(lanDiscoveryProvider);
    final theme = Theme.of(context);
    final colors = context.lekisColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(LekisRadius.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(LekisSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.wifi_find_outlined, color: colors.onSurfaceVariant),
                const SizedBox(width: LekisSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        SourcesStrings.discoveryTitle,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: LekisSpacing.xs),
                      Text(
                        SourcesStrings.discoveryBody,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: LekisSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: _ScanButton(
                state: state,
                onScan: () => ref.read(lanDiscoveryProvider.notifier).scan(),
              ),
            ),
            if (state.scanning) ...[
              const SizedBox(height: LekisSpacing.md),
              const LinearProgressIndicator(),
              const SizedBox(height: LekisSpacing.sm),
              Text(
                SourcesStrings.discoveryScanningBody,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ] else if (state.error != null) ...[
              const SizedBox(height: LekisSpacing.md),
              Semantics(
                liveRegion: true,
                child: Text(
                  '${SourcesStrings.discoveryError}：${describeCoreError(state.error!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.danger,
                  ),
                ),
              ),
            ] else if (state.isEmpty) ...[
              const SizedBox(height: LekisSpacing.md),
              Text(
                SourcesStrings.discoveryEmpty,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ] else if (state.results.isNotEmpty) ...[
              const SizedBox(height: LekisSpacing.md),
              Text(
                SourcesStrings.discoveryFoundCount(state.results.length),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: LekisSpacing.xs),
              Text(
                SourcesStrings.discoveryPickHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: LekisSpacing.sm),
              for (final service in state.results)
                _DiscoveredTile(
                  key: ValueKey(
                    '${service.kind.name}:${service.host}:${service.port}:${service.path}',
                  ),
                  service: service,
                  onTap: () => onPick(service),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ScanButton extends StatelessWidget {
  const _ScanButton({required this.state, required this.onScan});

  final LanDiscoveryState state;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final scanning = state.scanning;
    final label = scanning
        ? SourcesStrings.scanningLan
        : state.hasScanned
        ? SourcesStrings.scanAgain
        : SourcesStrings.scanLan;
    final icon = scanning
        ? const SizedBox.square(
            dimension: LekisSpacing.lg,
            child: CircularProgressIndicator(strokeWidth: LekisSpacing.xxs),
          )
        : Icon(state.hasScanned ? Icons.refresh : Icons.search);
    final onPressed = scanning ? null : onScan;
    if (state.hasScanned) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, LekisSizes.touchTargetMin),
        ),
        onPressed: onPressed,
        icon: icon,
        label: Text(label),
      );
    }
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, LekisSizes.touchTargetMin),
      ),
      onPressed: onPressed,
      icon: icon,
      label: Text(label),
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
