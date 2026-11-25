// 「在你的网络上发现」：打开添加音源时自动扫描，结果放在本地文件夹下面。
//
// 结果只来自核心的真实发现。SMB / WebDAV 点一下会带着地址进入表单；
// DLNA 只作为「这台机器可能有 SMB 共享」的提示。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../rust/api/dto.dart';
import '../../../theme/tokens.dart';
import '../../settings/widgets/settings_widgets.dart';
import '../common.dart';
import '../discovered_service_info.dart';
import '../discovery_providers.dart';
import '../strings.dart';

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

    final description = !state.hasScanned || state.scanning
        ? SourcesStrings.discoveryScanningBody
        : state.error != null
        ? '${SourcesStrings.discoveryError}：${describeCoreError(state.error!)}'
        : state.results.isEmpty
        ? SourcesStrings.discoveryNothingYet
        : '${SourcesStrings.discoveryFoundCount(state.results.length)} · ${SourcesStrings.discoveryPickHint}';
    return SettingsSection(
      key: const ValueKey('lan-discovery'),
      title: SourcesStrings.discoveryTitle,
      children: [
        SettingsTile(
          icon: Icons.wifi_find_outlined,
          title: SourcesStrings.scanLan,
          subtitle: Semantics(
            liveRegion: true,
            child: Text(
              description,
              style: state.error == null
                  ? muted
                  : muted?.copyWith(color: colors.danger),
            ),
          ),
          trailing: state.scanning
              ? const SizedBox.square(
                  dimension: LekisSpacing.lg,
                  child: CircularProgressIndicator(
                    strokeWidth: LekisSpacing.xxs,
                  ),
                )
              : IconButton(
                  key: const ValueKey('lan-discovery-rescan'),
                  tooltip: SourcesStrings.scanAgain,
                  onPressed: () =>
                      ref.read(lanDiscoveryProvider.notifier).scan(),
                  icon: const Icon(Icons.refresh_rounded),
                ),
        ),
        for (final service in state.results)
          _DiscoveredTile(
            key: ValueKey(
              '${service.kind.name}:${service.host}:${service.port}:${service.path}',
            ),
            service: service,
            onTap: () => widget.onPick(service),
          ),
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
    return SettingsTile(
      icon: service.icon,
      title: service.name,
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
      chevron: true,
      onTap: onTap,
    );
  }
}
