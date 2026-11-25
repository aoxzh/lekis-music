// 存储管理页（OFF-04）与 NAS 流媒体播放缓存上限配置（OFF-03）。
//
// 按类别展示占用比例（封面缓存、流媒体播放缓存、离线下载、其他临时缓存、数据库），
// 支持按类别清理与一键清理全部缓存（保留离线下载与数据库）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/storage.dart' as storage_api;
import '../../theme/theme.dart';
import '../sources/common.dart';
import 'settings_guard.dart';
import 'settings_providers.dart';
import 'strings.dart';
import 'widgets/settings_widgets.dart';

/// 存储占用状态 Provider（自动从 Rust 核心查询）。
final storageUsageProvider = FutureProvider<storage_api.StorageUsageDto>(
  (ref) => storage_api.storageUsage(),
);

/// 可选的流媒体播放缓存上限（MB；0 = 关闭）。
const List<int> kStreamCacheLimitOptionsMb = [
  0,
  512,
  1024,
  2048,
  5120,
  10240,
];

/// 把字节数格式化为易读大小（1024 进制）。
String formatStorageBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024.0;
  var unit = 0;
  while (value >= 1024.0 && unit < units.length - 1) {
    value /= 1024.0;
    unit++;
  }
  final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String _formatLimitMb(int mb) {
  if (mb <= 0) return SettingsStrings.storageLimitOff;
  if (mb >= 1024 && mb % 1024 == 0) return '${mb ~/ 1024} GB';
  return '$mb MB';
}

/// 高级设置里的存储管理入口行。
class StorageSettingsTile extends ConsumerWidget {
  const StorageSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(storageUsageProvider);
    final memBytes = PaintingBinding.instance.imageCache.currentSizeBytes;
    final subtitle = usage.when(
      data: (u) {
        final total = u.totalBytes.toInt() + memBytes;
        return '${SettingsStrings.storageHint} · ${formatStorageBytes(total)}';
      },
      loading: () => SettingsStrings.storageHint,
      error: (_, _) => SettingsStrings.storageHint,
    );
    return SettingsTile(
      key: const ValueKey('settings.storage'),
      icon: Icons.storage_rounded,
      title: SettingsStrings.storage,
      subtitle: Text(subtitle),
      chevron: true,
      onTap: () => Navigator.of(context).push(StorageManagementPage.route()),
    );
  }
}

/// 存储管理二级页面。
class StorageManagementPage extends ConsumerStatefulWidget {
  const StorageManagementPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (_) => const StorageManagementPage(),
  );

  @override
  ConsumerState<StorageManagementPage> createState() =>
      _StorageManagementPageState();
}

class _StorageManagementPageState extends ConsumerState<StorageManagementPage> {
  bool _busy = false;

  Future<void> _refresh() async {
    ref.invalidate(storageUsageProvider);
    await ref.read(storageUsageProvider.future).catchError((_) =>
        storage_api.StorageUsageDto(
          artworkBytes: BigInt.zero,
          artworkCount: BigInt.zero,
          streamCacheBytes: BigInt.zero,
          streamCacheCount: BigInt.zero,
          streamCacheLimitMb: BigInt.from(2048),
          offlineBytes: BigInt.zero,
          offlineCount: BigInt.zero,
          databaseBytes: BigInt.zero,
          otherCacheBytes: BigInt.zero,
          totalBytes: BigInt.zero,
        ));
  }

  Future<void> _clearCategory(
    storage_api.StorageCategoryDto category, {
    bool confirmOffline = false,
  }) async {
    if (_busy) return;
    if (confirmOffline) {
      final confirmed = await showLekisPanel<bool>(
        context,
        builder: (dialog) => LekisPanel(
          title: SettingsStrings.storageConfirmOfflineTitle,
          body: Text(SettingsStrings.storageConfirmOfflineBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text(SettingsStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(SettingsStrings.storageClear),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _busy = true);
    try {
      var freedMem = 0;
      if (category == storage_api.StorageCategoryDto.artwork ||
          category == storage_api.StorageCategoryDto.allCaches) {
        final cache = PaintingBinding.instance.imageCache;
        freedMem = cache.currentSizeBytes;
        cache.clear();
        cache.clearLiveImages();
      }
      final freedDisk = await storage_api.clearStorage(category: category);
      ref.invalidate(storageUsageProvider);
      if (mounted) {
        showFeatureSnack(
          context,
          SettingsStrings.storageCleared(
            formatStorageBytes(freedDisk.toInt() + freedMem),
          ),
        );
      }
    } catch (e) {
      if (mounted) showFeatureSnack(context, describeCoreError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setLimitMb(int mb) async {
    await settingsGuard(context, () async {
      await ref
          .read(settingProvider(SettingKeys.streamCacheLimitMb).notifier)
          .set(mb.toString());
      ref.invalidate(storageUsageProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final usageAsync = ref.watch(storageUsageProvider);
    final limitSetting = ref.watch(
      settingProvider(SettingKeys.streamCacheLimitMb),
    );
    final memBytes = PaintingBinding.instance.imageCache.currentSizeBytes;

    return SettingsScaffold(
      title: SettingsStrings.storage,
      actions: [
        IconButton(
          tooltip: SettingsStrings.storageRefresh,
          onPressed: _busy ? null : _refresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      body: usageAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(LekisSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(describeCoreError(err)),
                const SizedBox(height: LekisSpacing.md),
                FilledButton(
                  onPressed: _refresh,
                  child: Text(SettingsStrings.retry),
                ),
              ],
            ),
          ),
        ),
        data: (usage) {
          final artworkBytes = usage.artworkBytes.toInt() + memBytes;
          final streamBytes = usage.streamCacheBytes.toInt();
          final offlineBytes = usage.offlineBytes.toInt();
          final otherBytes = usage.otherCacheBytes.toInt();
          final dbBytes = usage.databaseBytes.toInt();
          final totalBytes =
              artworkBytes + streamBytes + offlineBytes + otherBytes + dbBytes;
          final clearableCachesBytes = artworkBytes + streamBytes + otherBytes;

          final savedLimit =
              int.tryParse(limitSetting.value ?? '') ??
              usage.streamCacheLimitMb.toInt();
          final selectedLimit = kStreamCacheLimitOptionsMb.contains(savedLimit)
              ? savedLimit
              : 2048;

          return SettingsListView(
            children: [
              _StorageOverviewCard(
                totalBytes: totalBytes,
                artworkBytes: artworkBytes,
                streamBytes: streamBytes,
                offlineBytes: offlineBytes,
                otherBytes: otherBytes,
                dbBytes: dbBytes,
              ),
              const SizedBox(height: LekisSpacing.md),
              SettingsSection(
                title: SettingsStrings.storageStreamCacheSection,
                children: [
                  SettingsTile(
                    icon: Icons.cloud_done_outlined,
                    title: SettingsStrings.storageCategoryStreamCache,
                    subtitle: Text(
                      '${formatStorageBytes(streamBytes)} / '
                      '${_formatLimitMb(savedLimit)} · '
                      '${SettingsStrings.storageTracksCount(usage.streamCacheCount.toInt())}',
                    ),
                    trailing: TextButton(
                      onPressed: _busy || streamBytes == 0
                          ? null
                          : () => _clearCategory(
                              storage_api.StorageCategoryDto.streamCache,
                            ),
                      child: Text(SettingsStrings.storageClear),
                    ),
                  ),
                  SettingsBlockTile(
                    key: const ValueKey('storage.stream-limit'),
                    icon: Icons.speed_rounded,
                    title: SettingsStrings.storageStreamCacheLimit,
                    hint: SettingsStrings.storageStreamCacheLimitHint,
                    child: Wrap(
                      spacing: LekisSpacing.sm,
                      runSpacing: LekisSpacing.xs,
                      children: [
                        for (final mb in kStreamCacheLimitOptionsMb)
                          ChoiceChip(
                            label: Text(_formatLimitMb(mb)),
                            selected: selectedLimit == mb,
                            onSelected: _busy ? null : (_) => _setLimitMb(mb),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              SettingsSection(
                title: SettingsStrings.storageBreakdown,
                children: [
                  SettingsTile(
                    icon: Icons.image_outlined,
                    title: SettingsStrings.storageCategoryArtwork,
                    subtitle: Text(
                      '${formatStorageBytes(artworkBytes)} · '
                      '${SettingsStrings.storageFilesCount(usage.artworkCount.toInt())}'
                      '${memBytes > 0 ? ' · ${SettingsStrings.storageMemoryCacheHint(formatStorageBytes(memBytes))}' : ''}',
                    ),
                    trailing: TextButton(
                      onPressed: _busy || artworkBytes == 0
                          ? null
                          : () => _clearCategory(
                              storage_api.StorageCategoryDto.artwork,
                            ),
                      child: Text(SettingsStrings.storageClear),
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.download_done_rounded,
                    title: SettingsStrings.storageCategoryOffline,
                    subtitle: Text(
                      '${formatStorageBytes(offlineBytes)} · '
                      '${SettingsStrings.storageTracksCount(usage.offlineCount.toInt())}',
                    ),
                    trailing: TextButton(
                      onPressed: _busy || offlineBytes == 0
                          ? null
                          : () => _clearCategory(
                              storage_api.StorageCategoryDto.offlineDownloads,
                              confirmOffline: true,
                            ),
                      child: Text(SettingsStrings.storageClear),
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.cleaning_services_outlined,
                    title: SettingsStrings.storageCategoryOther,
                    subtitle: Text(formatStorageBytes(otherBytes)),
                    trailing: TextButton(
                      onPressed: _busy || otherBytes == 0
                          ? null
                          : () => _clearCategory(
                              storage_api.StorageCategoryDto.otherCache,
                            ),
                      child: Text(SettingsStrings.storageClear),
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.table_chart_outlined,
                    title: SettingsStrings.storageCategoryDatabase,
                    subtitle: Text(
                      '${formatStorageBytes(dbBytes)} · ${SettingsStrings.storageDatabaseHint}',
                    ),
                  ),
                  SettingsTile(
                    key: const ValueKey('storage.clear-all-caches'),
                    icon: Icons.delete_sweep_outlined,
                    title: SettingsStrings.storageClearAllCaches,
                    subtitle: Text(SettingsStrings.storageClearAllCachesHint),
                    trailing: FilledButton.tonal(
                      onPressed: _busy || clearableCachesBytes == 0
                          ? null
                          : () => _clearCategory(
                              storage_api.StorageCategoryDto.allCaches,
                            ),
                      child: Text(
                        clearableCachesBytes > 0
                            ? formatStorageBytes(clearableCachesBytes)
                            : SettingsStrings.storageClear,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StorageOverviewCard extends StatelessWidget {
  const _StorageOverviewCard({
    required this.totalBytes,
    required this.artworkBytes,
    required this.streamBytes,
    required this.offlineBytes,
    required this.otherBytes,
    required this.dbBytes,
  });

  final int totalBytes;
  final int artworkBytes;
  final int streamBytes;
  final int offlineBytes;
  final int otherBytes;
  final int dbBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final segments = [
      (
        SettingsStrings.storageCategoryStreamCache,
        streamBytes,
        scheme.primary,
      ),
      (
        SettingsStrings.storageCategoryOffline,
        offlineBytes,
        scheme.tertiary,
      ),
      (
        SettingsStrings.storageCategoryArtwork,
        artworkBytes,
        scheme.secondary,
      ),
      (
        SettingsStrings.storageCategoryDatabase,
        dbBytes,
        scheme.outline,
      ),
      (
        SettingsStrings.storageCategoryOther,
        otherBytes,
        scheme.outlineVariant,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
      child: Container(
        padding: const EdgeInsets.all(LekisSpacing.lg),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(LekisRadius.lg),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              SettingsStrings.storageTotalUsed,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              formatStorageBytes(totalBytes),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: LekisSpacing.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 10,
                child: totalBytes <= 0
                    ? ColoredBox(color: scheme.surfaceContainerHighest)
                    : Row(
                        children: [
                          for (final (_, bytes, color) in segments)
                            if (bytes > 0)
                              Expanded(
                                flex: (bytes * 1000 / totalBytes)
                                    .round()
                                    .clamp(1, 1000),
                                child: ColoredBox(color: color),
                              ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: LekisSpacing.md),
            Wrap(
              spacing: LekisSpacing.md,
              runSpacing: LekisSpacing.xs,
              children: [
                for (final (label, bytes, color) in segments)
                  if (bytes > 0)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$label · ${formatStorageBytes(bytes)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
