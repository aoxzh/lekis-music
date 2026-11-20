// 资料库检查：重复歌曲与库健康（LIB-10 / LIB-11）。
//
// 页面只读 SQLite 的分页结果；唯一会主动读源文件的是"扫描损坏文件"。
// 和其它设置子页面一样用共用的页头 / 平铺行，不用卡片。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/downloads_models.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/library_health_providers.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/features/sources/common.dart'
    show describeCoreError, showFeatureSnack;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// 资料库检查页。从设置 > 资料库进入。
class LibraryHealthPage extends ConsumerWidget {
  const LibraryHealthPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/settings/library-health'),
    builder: (_) => const LibraryHealthPage(),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: SettingsScaffold(
        title: '资料库检查',
        actions: [
          IconButton(
            tooltip: '重新统计',
            onPressed: () {
              ref.invalidate(libraryHealthSummaryProvider);
              ref.invalidate(duplicateGroupListProvider);
              ref.invalidate(healthEntriesProvider);
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        body: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionTabs(),
            Expanded(
              child: TabBarView(children: [_DuplicatesTab(), _HealthTab()]),
            ),
          ],
        ),
      ),
    );
  }
}

/// 页头下方的两个分区，左对齐在页边距上。
class _SectionTabs extends StatelessWidget {
  const _SectionTabs();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = settingsContentPadding(context, constraints.maxWidth);
      return TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerHeight: 0,
        padding: EdgeInsets.only(left: inset.left, right: inset.right),
        tabs: const [
          Tab(text: '重复歌曲'),
          Tab(text: '库健康'),
        ],
      );
    },
  );
}

/// 分页列表的公共外壳：设置页的边距、平铺行、行间分隔线。
class _FlatList extends StatelessWidget {
  const _FlatList({
    required this.header,
    required this.itemCount,
    required this.itemBuilder,
  });

  final Widget header;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListView.separated(
      padding: settingsContentPadding(context, constraints.maxWidth),
      itemCount: itemCount + 1,
      separatorBuilder: (_, index) => index == 0
          ? const SizedBox.shrink()
          : const Divider(height: 1, indent: settingsTextInset),
      itemBuilder: (context, index) => index == 0
          ? header
          : Material(
              type: MaterialType.transparency,
              child: itemBuilder(context, index - 1),
            ),
    ),
  );
}

// ---------------------------------------------------------------------------
// 重复歌曲
// ---------------------------------------------------------------------------

class _DuplicatesTab extends ConsumerWidget {
  const _DuplicatesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(duplicateGroupListProvider);
    final summary = ref.watch(libraryHealthSummaryProvider).value;
    final header = _DuplicatesHeader(summary: summary);

    return ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        if (list.error != null) {
          return _FlatList(
            header: header,
            itemCount: 1,
            itemBuilder: (_, _) =>
                _InlineError(error: list.error!, onRetry: list.retry),
          );
        }
        if (list.isInitialLoading) {
          return _FlatList(
            header: header,
            itemCount: 1,
            itemBuilder: (_, _) => const _LoadingBlock(),
          );
        }
        if (list.isEmpty) {
          return _FlatList(
            header: header,
            itemCount: 1,
            itemBuilder: (_, _) => const _EmptyDuplicates(),
          );
        }
        return _FlatList(
          header: header,
          itemCount: list.itemCount,
          itemBuilder: (context, index) {
            final group = list.itemAt(index);
            if (group == null) return const _LoadingRow();
            return _DuplicateGroupRow(group: group);
          },
        );
      },
    );
  }
}

class _DuplicatesHeader extends StatelessWidget {
  const _DuplicatesHeader({required this.summary});

  final LibraryHealthSummaryDto? summary;

  @override
  Widget build(BuildContext context) {
    final groups = summary?.duplicateGroups.toInt();
    final tracks = summary?.totalTracks.toInt();
    return Padding(
      padding: const EdgeInsets.only(bottom: LekisSpacing.md),
      child: SettingsTile(
        icon: Icons.content_copy_rounded,
        title: groups == null ? '正在统计重复歌曲…' : '发现 $groups 组重复',
        subtitle: Text(
          [
            if (tracks != null) '资料库共 $tracks 首曲目。',
            '按规范化后的标题、艺人、专辑和 ±2 秒时长匹配；同一组出现多个 '
                'MusicBrainz 录音 ID 时视为不同录音。',
            '建议保留无损、采样率 / 位深 / 比特率更高、文件更大的版本；不会自动删除任何文件。',
          ].join('\n'),
        ),
      ),
    );
  }
}

class _DuplicateGroupRow extends StatelessWidget {
  const _DuplicateGroupRow({required this.group});

  final DuplicateGroupDto group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    DuplicateTrackDto? keep;
    for (final track in group.tracks) {
      if (track.suggestedKeep) {
        keep = track;
        break;
      }
    }
    final title = group.title.trim().isEmpty ? '未知标题' : group.title;
    final artist = group.artistLine.trim().isEmpty ? '未知艺人' : group.artistLine;
    final album = group.albumTitle?.trim();
    final parts = <String>[
      artist,
      if (album != null && album.isNotEmpty) album,
      '${group.tracks.length} 个版本',
    ];
    if (keep != null && keep.format != null) {
      parts.add('建议保留 ${keep.format}');
    }
    return ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: settingsRowInset),
      leading: SettingsLeadingIcon(Icons.library_music_outlined),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: Text(
        parts.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      children: [
        for (final track in group.tracks)
          _DuplicateVersionRow(track: track, title: title),
      ],
    );
  }
}

class _DuplicateVersionRow extends ConsumerWidget {
  const _DuplicateVersionRow({required this.track, required this.title});

  final DuplicateTrackDto track;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final keep = track.suggestedKeep;
    final tech = _trackTech(
      format: track.format,
      codec: track.codec,
      bitrateKbps: track.bitrateKbps,
      bitDepth: track.bitDepth,
      sampleRate: track.sampleRate,
      sizeBytes: track.sizeBytes.toInt(),
      durationMs: track.durationMs.toInt(),
    );
    final meta = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return InkWell(
      onTap: track.albumId == null
          ? null
          : () =>
                Navigator.of(context)
                    .push(AlbumDetailPage.route(track.albumId!.toInt())),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          settingsTextInset,
          LekisSpacing.sm,
          LekisSpacing.sm,
          LekisSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                keep
                    ? Icons.check_circle_rounded
                    : Icons.delete_outline_rounded,
                size: 18,
                color: keep ? colors.accent : colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: LekisSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: LekisSpacing.xs,
                    runSpacing: LekisSpacing.xs,
                    children: [
                      Text(
                        keep ? '建议保留' : '建议删除',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: keep ? colors.accent : colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (track.title.trim().isNotEmpty &&
                          track.title.trim() != title)
                        Text(
                          track.title,
                          style: meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                  const SizedBox(height: LekisSpacing.xxs),
                  Text(
                    _displayPath(track.path),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: meta,
                  ),
                  if (tech.isNotEmpty) ...[
                    const SizedBox(height: LekisSpacing.xxs),
                    Text(tech, style: meta),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: '播放这个版本',
              onPressed: () => ref.read(playerActionsProvider).playTracks([
                track.trackId.toInt(),
              ]),
              icon: const Icon(Icons.play_arrow_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDuplicates extends StatelessWidget {
  const _EmptyDuplicates();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 380,
      child: LekisEmptyState(
        eyebrow: '重复歌曲',
        title: '没有发现重复歌曲',
        message: '标签越完整，检测越准确。修改标签后回到这里按刷新重新统计；不会读取或修改音频文件。',
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 库健康
// ---------------------------------------------------------------------------

class _HealthTab extends ConsumerWidget {
  const _HealthTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(libraryHealthSummaryProvider).value;
    final tab = ref.watch(healthKindProvider);
    final list = ref.watch(healthEntriesProvider(tab));
    final scan = ref.watch(healthScanProvider);
    final scanning = scan.isLoading;
    final header = _HealthHeader(
      summary: summary,
      selected: tab,
      scanning: scanning,
      onSelect: (next) => ref.read(healthKindProvider.notifier).set(next),
      onScan: () => _scan(context, ref),
    );

    return ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        if (list.error != null) {
          return _FlatList(
            header: header,
            itemCount: 1,
            itemBuilder: (_, _) =>
                _InlineError(error: list.error!, onRetry: list.retry),
          );
        }
        if (list.isInitialLoading) {
          return _FlatList(
            header: header,
            itemCount: 1,
            itemBuilder: (_, _) => const _LoadingBlock(),
          );
        }
        if (list.isEmpty) {
          return _FlatList(
            header: header,
            itemCount: 1,
            itemBuilder: (_, _) => _EmptyHealth(
              tab: tab,
              totalTracks: summary?.totalTracks.toInt() ?? 0,
              summaryLoaded: summary != null,
              onScan: scanning ? null : () => _scan(context, ref),
            ),
          );
        }
        return _FlatList(
          header: header,
          itemCount: list.itemCount,
          itemBuilder: (context, index) {
            final entry = list.itemAt(index);
            if (entry == null) return const _LoadingRow();
            return _HealthEntryRow(entry: entry);
          },
        );
      },
    );
  }

  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    final report = await ref.read(healthScanProvider.notifier).scan();
    if (!context.mounted) return;
    if (report == null) {
      final error = ref.read(healthScanProvider).error;
      showFeatureSnack(
        context,
        error == null ? '扫描失败' : '扫描失败：${describeCoreError(error)}',
      );
      return;
    }
    final checked = report.filesChecked.toInt();
    final unreadable = report.unreadable.toInt();
    final failed = report.failedSources;
    showFeatureSnack(
      context,
      failed > 0
          ? '扫描完成：检查 $checked 个文件，$unreadable 个不可读；$failed 个音源打不开'
          : '扫描完成：检查 $checked 个文件，$unreadable 个不可读',
    );
  }
}

class _HealthHeader extends StatelessWidget {
  const _HealthHeader({
    required this.summary,
    required this.selected,
    required this.scanning,
    required this.onSelect,
    required this.onScan,
  });

  final LibraryHealthSummaryDto? summary;
  final HealthTabKind selected;
  final bool scanning;
  final ValueChanged<HealthTabKind> onSelect;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final tracks = summary?.totalTracks.toInt();
    BigInt? countOf(HealthTabKind kind) => switch (kind) {
      HealthTabKind.missingCover => summary?.missingCover,
      HealthTabKind.missingLyrics => summary?.missingLyrics,
      HealthTabKind.missingTags => summary?.missingTags,
      HealthTabKind.fakeLossless => summary?.fakeLossless,
      HealthTabKind.unreadable => summary?.unreadableFiles,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: '扫描',
          children: [
            SettingsTile(
              icon: Icons.health_and_safety_outlined,
              title: tracks == null ? '正在读取资料库…' : '资料库共 $tracks 首曲目',
              subtitle: const Text(
                '扫描只检查每个文件能否打开并读取 1 个字节；不做频谱分析，也不会修改文件。'
                'NAS 上的大资料库可能需要几分钟。',
              ),
              trailing: scanning
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(onPressed: onScan, child: const Text('扫描损坏文件')),
            ),
          ],
        ),
        SettingsSection(
          title: '问题类型',
          children: [
            for (final kind in HealthTabKind.values)
              Semantics(
                selected: kind == selected,
                child: SettingsTile(
                  icon: _healthIcon(kind.kind),
                  title: kind.label,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_count(countOf(kind))),
                      const SizedBox(width: LekisSpacing.sm),
                      Icon(
                        kind == selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 20,
                        color: kind == selected
                            ? colors.accent
                            : colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                  onTap: () => onSelect(kind),
                ),
              ),
          ],
        ),
        SettingsSectionHeader(selected.label),
      ],
    );
  }

  static String _count(BigInt? value) =>
      value == null ? '—' : value.toInt().toString();
}

class _HealthEntryRow extends ConsumerWidget {
  const _HealthEntryRow({required this.entry});

  final LibraryHealthEntryDto entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final title = entry.title.trim().isEmpty ? '未知标题' : entry.title;
    final artist = entry.artistLine.trim().isEmpty ? '未知艺人' : entry.artistLine;
    final album = entry.albumTitle?.trim();
    final tech = _trackTech(
      format: entry.format,
      codec: entry.codec,
      bitrateKbps: entry.bitrateKbps,
      bitDepth: entry.bitDepth,
      sampleRate: entry.sampleRate,
      sizeBytes: entry.sizeBytes.toInt(),
      durationMs: entry.durationMs.toInt(),
    );
    final lines = <Widget>[
      Text(
        [artist, if (album != null && album.isNotEmpty) album].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      if (entry.path.isNotEmpty)
        Text(
          _displayPath(entry.path),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      if (entry.detail != null && entry.detail!.isNotEmpty)
        Text(
          entry.detail!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
        ),
      if (tech.isNotEmpty) Text(tech),
    ];
    return SettingsTile(
      icon: _healthIcon(entry.kind),
      title: title,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines.length; i++) ...[
            if (i > 0) const SizedBox(height: LekisSpacing.xxs),
            lines[i],
          ],
        ],
      ),
      trailing: entry.kind == HealthIssueKindDto.unreadable
          ? null
          : IconButton(
              tooltip: '播放',
              onPressed: () => ref.read(playerActionsProvider).playTracks([
                entry.trackId.toInt(),
              ]),
              icon: const Icon(Icons.play_arrow_rounded),
            ),
      onTap: entry.albumId == null
          ? null
          : () =>
                Navigator.of(context)
                    .push(AlbumDetailPage.route(entry.albumId!.toInt())),
    );
  }
}

class _EmptyHealth extends StatelessWidget {
  const _EmptyHealth({
    required this.tab,
    required this.totalTracks,
    required this.summaryLoaded,
    required this.onScan,
  });

  final HealthTabKind tab;
  final int totalTracks;
  final bool summaryLoaded;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    if (!summaryLoaded) {
      return const SizedBox(
        height: 380,
        child: LekisEmptyState(
          eyebrow: '库健康',
          title: '正在读取资料库…',
          message: '统计完曲目和重复组后，这里会显示缺封面、缺歌词、空标签等问题。',
        ),
      );
    }
    if (totalTracks == 0) {
      return const SizedBox(
        height: 380,
        child: LekisEmptyState(
          eyebrow: '库健康',
          title: '资料库还是空的',
          message: '先在“音源”里添加本地文件夹或 NAS，扫描完成后就能检查封面、歌词、标签和重复歌曲。',
        ),
      );
    }
    final message = switch (tab) {
      HealthTabKind.missingCover => '每首曲目都有封面（曲目封面或专辑封面）。',
      HealthTabKind.missingLyrics => '没有发现缺少歌词的曲目。',
      HealthTabKind.missingTags => '标题和艺人都有值，没有发现空标签。',
      HealthTabKind.fakeLossless => '没有发现码率或文件大小异常低的疑似假无损；这里只做简单启发式，不看频谱。',
      HealthTabKind.unreadable => '上一轮扫描没有发现损坏或不可读的文件。源文件变化后可以重新扫描。',
    };
    return SizedBox(
      height: 380,
      child: LekisEmptyState(
        eyebrow: tab.label,
        title: tab == HealthTabKind.unreadable ? '没有不可读文件' : '这一类没有问题',
        message: message,
        action: tab == HealthTabKind.unreadable
            ? FilledButton.tonalIcon(
                onPressed: onScan,
                icon: const Icon(Icons.health_and_safety_outlined),
                label: const Text('扫描损坏文件'),
              )
            : null,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

class _InlineError extends StatelessWidget {
  const _InlineError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SettingsTile(
    icon: Icons.error_outline_rounded,
    title: '读取失败',
    subtitle: Text(describeCoreError(error)),
    trailing: TextButton(onPressed: onRetry, child: const Text('重试')),
  );
}

class _LoadingBlock extends StatelessWidget {
  const _LoadingBlock();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: LekisSpacing.xxl),
    child: Center(child: CircularProgressIndicator()),
  );
}

/// 还没加载到的分页行：占住一行的高度，避免滚动时跳动。
class _LoadingRow extends StatelessWidget {
  const _LoadingRow();

  @override
  Widget build(BuildContext context) => const SizedBox(height: 72);
}

IconData _healthIcon(HealthIssueKindDto kind) => switch (kind) {
  HealthIssueKindDto.missingCover => Icons.image_not_supported_outlined,
  HealthIssueKindDto.missingLyrics => Icons.lyrics_outlined,
  HealthIssueKindDto.missingTags => Icons.sell_outlined,
  HealthIssueKindDto.fakeLossless => Icons.graphic_eq_rounded,
  HealthIssueKindDto.unreadable => Icons.broken_image_outlined,
};

String _displayPath(String path) => path.trim().isEmpty ? '（没有文件路径）' : path;

String _trackTech({
  required String? format,
  required String? codec,
  required int? bitrateKbps,
  required int? bitDepth,
  required int? sampleRate,
  required int sizeBytes,
  required int durationMs,
}) {
  final parts = <String>[];
  if (format != null && format.isNotEmpty) {
    parts.add(format);
  } else if (codec != null && codec.isNotEmpty) {
    parts.add(codec.toUpperCase());
  }
  if (bitrateKbps != null && bitrateKbps > 0) {
    parts.add('$bitrateKbps kbps');
  }
  if (bitDepth != null && format == null) {
    parts.add('$bitDepth bit');
  }
  if (sampleRate != null && sampleRate > 0 && format == null) {
    parts.add(_sampleRate(sampleRate));
  }
  if (sizeBytes > 0) parts.add(formatBytes(sizeBytes));
  if (durationMs > 0) parts.add(_duration(durationMs));
  return parts.join(' · ');
}

String _sampleRate(int hz) => hz % 1000 == 0
    ? '${hz ~/ 1000} kHz'
    : '${(hz / 1000).toStringAsFixed(1)} kHz';

String _duration(int ms) {
  final total = ms ~/ 1000;
  final minutes = total ~/ 60;
  final seconds = total % 60;
  if (minutes >= 60) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return '$hours:${rest.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
