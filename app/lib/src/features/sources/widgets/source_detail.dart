// 单个音源的详情：基本信息、凭据状态、状态、扫描进度，以及测试 / 编辑 / 重新扫描 / 删除。

import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../rust/api/core.dart' as core;
import '../../../rust/api/dto.dart';
import '../../../rust/api/error.dart';
import '../../../theme/tokens.dart';
import '../common.dart';
import '../source_draft.dart';
import '../source_kind_info.dart';
import '../sources_providers.dart';
import '../strings.dart';
import 'add_source.dart';
import 'source_status.dart';

class SourceDetail extends ConsumerStatefulWidget {
  const SourceDetail({super.key, required this.sourceId, this.onDeleted});

  final int sourceId;

  /// 宽窗口里删除后让父页面把右栏切回占位；窄窗口不传，默认返回上一页。
  final VoidCallback? onDeleted;

  @override
  ConsumerState<SourceDetail> createState() => _SourceDetailState();
}

class _SourceDetailState extends ConsumerState<SourceDetail> {
  bool _testing = false;
  bool _deleting = false;

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(
      sourcesProvider.select(
        (s) => s.value?.where((e) => e.id == widget.sourceId).firstOrNull,
      ),
    );
    if (source == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final runtime =
        ref.watch(sourceRuntimeProvider.select((m) => m[widget.sourceId])) ??
        const SourceRuntime();
    final history = ref.watch(
      sourceScanHistoryProvider.select((h) => h.value?[widget.sourceId]),
    );
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final error = runtime.lastError;
    final username = (source.options['username'] ?? '').trim();
    final credentialRef = source.credentialRef?.trim() ?? '';
    final credentialSaved =
        credentialRef.isNotEmpty &&
        core.hasCredential(credentialRef: credentialRef);
    final busy = _testing || _deleting;
    // 测试连接、凭据、备用地址只属于网络音源（NAS、媒体服务器）。
    final network = source.kind.isNetwork;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: featureMaxContentWidth),
        child: ListView(
          padding: featureScrollPadding(context),
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
            for (final (i, a) in source.addresses.indexed)
              _InfoRow(
                label: !network
                    ? SourcesStrings.detailPath
                    : i == 0
                    ? SourcesStrings.detailAddress
                    : SourcesStrings.detailAlternate,
                value: displayAddress(a),
              ),
            if (network && username.isNotEmpty)
              _InfoRow(label: SourcesStrings.detailUsername, value: username),
            if (network)
              _InfoRow(
                label: SourcesStrings.detailCredential,
                value: _credentialLabel(source, credentialSaved, username),
                leading: Icon(
                  credentialSaved ? Icons.lock : Icons.lock_open,
                  size: LekisSpacing.lg,
                  color: credentialSaved
                      ? colors.accent
                      : colors.onSurfaceVariant,
                ),
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
              value: lastScanLabel(runtime, history),
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
                if (network)
                  OutlinedButton.icon(
                    key: const ValueKey('source-test-connection'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, LekisSizes.touchTargetMin),
                    ),
                    onPressed: busy ? null : () => _test(context, source),
                    icon: _testing
                        ? const SizedBox.square(
                            dimension: LekisSpacing.lg,
                            child: CircularProgressIndicator(
                              strokeWidth: LekisSpacing.xxs,
                            ),
                          )
                        : const Icon(Icons.wifi_tethering),
                    label: Text(
                      _testing
                          ? SourcesStrings.testing
                          : SourcesStrings.testConnection,
                    ),
                  ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, LekisSizes.touchTargetMin),
                  ),
                  onPressed: busy ? null : () => _edit(context, source),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(SourcesStrings.edit),
                ),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, LekisSizes.touchTargetMin),
                  ),
                  onPressed: runtime.scanning || busy
                      ? null
                      : () => _rescan(context, source),
                  icon: const Icon(Icons.refresh),
                  label: Text(SourcesStrings.rescan),
                ),
                if (source.kind.isFilesystem)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, LekisSizes.touchTargetMin),
                    ),
                    onPressed: busy ? null : () => _sync(context),
                    icon: const Icon(Icons.sync),
                    label: Text(SourcesStrings.syncNow),
                  ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, LekisSizes.touchTargetMin),
                    foregroundColor: colors.danger,
                  ),
                  onPressed: busy ? null : () => _delete(context, source),
                  icon: _deleting
                      ? const SizedBox.square(
                          dimension: LekisSpacing.lg,
                          child: CircularProgressIndicator(
                            strokeWidth: LekisSpacing.xxs,
                          ),
                        )
                      : const Icon(Icons.delete_outline),
                  label: Text(SourcesStrings.deleteSource),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _credentialLabel(SourceConfigDto source, bool saved, String username) {
    if (saved) return SourcesStrings.credentialSaved;
    // NFSv3 按 IP 授权，没有账号密码。
    if (source.kind == SourceKindDto.nfs) {
      return SourcesStrings.credentialAnonymous;
    }
    if (source.kind == SourceKindDto.smb && username.isEmpty) {
      return SourcesStrings.credentialGuest;
    }
    if (source.kind == SourceKindDto.webDav && username.isEmpty) {
      return SourcesStrings.credentialAnonymous;
    }
    return SourcesStrings.credentialNotSet;
  }

  Future<void> _test(BuildContext context, SourceConfigDto source) async {
    setState(() => _testing = true);
    try {
      await ref.read(sourceActionsProvider).test(source);
      if (context.mounted) {
        showFeatureSnack(context, SourcesStrings.testSuccess);
      }
    } catch (e) {
      if (!context.mounted) return;
      if (_isAndroidPermissionError(source, e)) {
        await showAndroidPermissionDialog(context);
      } else {
        showFeatureSnack(context, describeCoreError(e));
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _edit(BuildContext context, SourceConfigDto source) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => EditSourcePage(source: source)),
    );
  }

  Future<void> _delete(BuildContext context, SourceConfigDto source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(SourcesStrings.deleteTitle),
        content: Text(SourcesStrings.deleteBody(source.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(SourcesStrings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.lekisColors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(SourcesStrings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    setState(() => _deleting = true);
    try {
      final cleaned = await ref.read(sourceActionsProvider).delete(source);
      if (!context.mounted) return;
      showFeatureSnack(
        context,
        cleaned ? SourcesStrings.deleted : SourcesStrings.deletedCredentialLeft,
      );
      final onDeleted = widget.onDeleted;
      if (onDeleted != null) {
        onDeleted();
      } else {
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      if (context.mounted) {
        showFeatureSnack(context, describeCoreError(e));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  bool _isAndroidPermissionError(SourceConfigDto source, Object error) =>
      source.kind == SourceKindDto.local &&
      Platform.isAndroid &&
      coreErrorKind(error) == ErrorKind.permissionDenied;

  Future<void> _rescan(BuildContext context, SourceConfigDto source) async {
    try {
      await ref.read(sourceActionsProvider).rescan(widget.sourceId);
    } catch (e) {
      if (!context.mounted) return;
      if (_isAndroidPermissionError(source, e)) {
        await showAndroidPermissionDialog(context);
      } else {
        showFeatureSnack(context, describeCoreError(e));
      }
    }
  }

  Future<void> _sync(BuildContext context) async {
    try {
      final r = await ref.read(sourceActionsProvider).syncNow(widget.sourceId);
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
        title: Text(SourcesStrings.androidPermissionTitle),
        content: Text(SourcesStrings.androidPermissionBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(SourcesStrings.ok),
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
