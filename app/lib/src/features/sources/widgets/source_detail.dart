// 单个音源的详情：基本信息、状态、扫描进度、重新扫描 / 同步。

import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../rust/api/dto.dart';
import '../../../rust/api/error.dart';
import '../../../theme/tokens.dart';
import '../common.dart';
import '../source_draft.dart';
import '../source_kind_info.dart';
import '../sources_providers.dart';
import '../strings.dart';
import 'source_status.dart';

class SourceDetail extends ConsumerWidget {
  const SourceDetail({super.key, required this.sourceId});

  final int sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(
      sourcesProvider.select(
        (s) => s.value?.where((e) => e.id == sourceId).firstOrNull,
      ),
    );
    if (source == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final runtime =
        ref.watch(sourceRuntimeProvider.select((m) => m[sourceId])) ??
        const SourceRuntime();
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final error = runtime.lastError;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: featureMaxContentWidth),
        child: ListView(
          padding: EdgeInsets.all(context.featureGutter),
          children: [
            Row(
              children: [
                SourceKindBadge(icon: source.kind.icon),
                const SizedBox(width: LekisSpacing.lg),
                Expanded(
                  child: Text(
                    source.name,
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: LekisSpacing.xl),
            _InfoRow(
              label: SourcesStrings.detailKind,
              value: source.kind.label,
            ),
            for (final a in source.addresses)
              _InfoRow(
                label: source.kind == SourceKindDto.local
                    ? SourcesStrings.detailPath
                    : SourcesStrings.detailAddress,
                value: displayAddress(a),
              ),
            _InfoRow(
              label: SourcesStrings.detailStatus,
              value: reachabilityLabel(source, runtime),
              leading: ReachabilityDot(
                reachable: source.enabled ? runtime.reachable : null,
              ),
            ),
            _InfoRow(
              label: SourcesStrings.detailLastScan,
              value: lastScanLabel(runtime),
            ),
            if (runtime.scanning) ...[
              const SizedBox(height: LekisSpacing.lg),
              ScanProgressView(runtime: runtime),
            ],
            if (error != null && !runtime.scanning) ...[
              const SizedBox(height: LekisSpacing.lg),
              Text(
                describeCoreError(error),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.danger,
                ),
              ),
            ],
            const SizedBox(height: LekisSpacing.xl),
            Wrap(
              spacing: LekisSpacing.sm,
              runSpacing: LekisSpacing.sm,
              children: [
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, LekisSizes.touchTargetMin),
                  ),
                  onPressed: runtime.scanning
                      ? null
                      : () => _rescan(context, ref, source),
                  icon: const Icon(Icons.refresh),
                  label: const Text(SourcesStrings.rescan),
                ),
                if (source.kind.isFilesystem)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, LekisSizes.touchTargetMin),
                    ),
                    onPressed: () => _sync(context, ref),
                    icon: const Icon(Icons.sync),
                    label: const Text(SourcesStrings.syncNow),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rescan(
    BuildContext context,
    WidgetRef ref,
    SourceConfigDto source,
  ) async {
    try {
      await ref.read(sourceActionsProvider).rescan(sourceId);
    } catch (e) {
      if (!context.mounted) return;
      if (source.kind == SourceKindDto.local &&
          Platform.isAndroid &&
          coreErrorKind(e) == ErrorKind.permissionDenied) {
        await showAndroidPermissionDialog(context);
      } else {
        showFeatureSnack(context, describeCoreError(e));
      }
    }
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    try {
      final r = await ref.read(sourceActionsProvider).syncNow(sourceId);
      if (context.mounted) {
        showFeatureSnack(
          context,
          SourcesStrings.syncDone(
            r.pushed.toInt(),
            r.pulled.toInt(),
            r.applied.toInt(),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) showFeatureSnack(context, describeCoreError(e));
    }
  }
}

/// 解释 Android 上为什么需要“音乐和音频”权限。
Future<void> showAndroidPermissionDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.folder_off_outlined),
        title: const Text(SourcesStrings.androidPermissionTitle),
        content: const Text(SourcesStrings.androidPermissionBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(SourcesStrings.ok),
          ),
        ],
      ),
    );

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.leading});

  final String label;
  final String value;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: LekisSizes.touchTargetMin * 2,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          if (leading != null) ...[
            leading!,
            const SizedBox(width: LekisSpacing.sm),
          ],
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
