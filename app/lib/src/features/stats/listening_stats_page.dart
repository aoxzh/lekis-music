// DIS-06: listening statistics / year in review.
//
// The page intentionally uses only aggregate data from the core: a 100k-track
// library must not stream every play event into Dart.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/sources/common.dart';
import 'package:lekis/src/features/stats/listening_stats_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

class ListeningStatsPage extends ConsumerStatefulWidget {
  const ListeningStatsPage({super.key});

  @override
  ConsumerState<ListeningStatsPage> createState() => _ListeningStatsPageState();
}

class _ListeningStatsPageState extends ConsumerState<ListeningStatsPage> {
  int? _year;

  @override
  Widget build(BuildContext context) {
    final years = ref.watch(listeningYearsProvider);
    final summary = ref.watch(listeningSummaryProvider(_year));
    final theme = Theme.of(context);
    final colors = context.lekisColors;

    return Scaffold(
      appBar: AppBar(title: const Text('听歌统计')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(listeningYearsProvider);
          ref.invalidate(listeningSummaryProvider(_year));
          await ref.read(listeningSummaryProvider(_year).future);
        },
        child: ListView(
          padding: EdgeInsets.symmetric(
            horizontal: pageGutterOf(context),
            vertical: LekisSpacing.lg,
          ),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: featureMaxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '你的听歌足迹',
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                      years.when(
                        data: (items) => DropdownButton<int?>(
                          value: _year,
                          hint: const Text('全部时间'),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('全部时间'),
                            ),
                            for (final y in items)
                              DropdownMenuItem<int?>(
                                value: y,
                                child: Text('$y 年'),
                              ),
                          ],
                          onChanged: (v) => setState(() => _year = v),
                        ),
                        loading: () => const SizedBox.shrink(),
                        error: (_, _) => const SizedBox.shrink(),
                      ),
                    ],
                  ),
                  const SizedBox(height: LekisSpacing.sm),
                  Text(
                    '统计来自本机播放记录；只在本地保存，不包含歌词或文件内容。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: LekisSpacing.lg),
                  summary.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: 64),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (e, _) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.error_outline),
                        title: const Text('读取听歌统计失败'),
                        subtitle: Text('$e'),
                      ),
                    ),
                    data: (data) => data.totalPlays == BigInt.zero
                        ? const _EmptyStats()
                        : _StatsBody(summary: data),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyStats extends StatelessWidget {
  const _EmptyStats();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            Icon(
              Icons.insights_outlined,
              size: 44,
              color: context.lekisColors.onSurfaceVariant,
            ),
            const SizedBox(height: LekisSpacing.md),
            Text('还没有听歌记录', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: LekisSpacing.xs),
            Text(
              '播放几首歌后，这里会显示听得最多的艺人、专辑和时段。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.lekisColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsBody extends ConsumerWidget {
  const _StatsBody({required this.summary});

  final ListeningSummaryDto summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hours = summary.totalPlayedMs.toDouble() / 3600000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Wrap(
              spacing: 28,
              runSpacing: 18,
              children: [
                _BigStat(
                  value: _formatHours(hours),
                  label: '累计收听',
                  icon: Icons.timer_outlined,
                ),
                _BigStat(
                  value: '${summary.totalPlays}',
                  label: '播放次数',
                  icon: Icons.play_arrow_rounded,
                ),
                _BigStat(
                  value: '${summary.uniqueArtists}',
                  label: '艺人',
                  icon: Icons.people_alt_outlined,
                ),
                _BigStat(
                  value: '${summary.uniqueAlbums}',
                  label: '专辑',
                  icon: Icons.album_outlined,
                ),
                _BigStat(
                  value: '${summary.uniqueTracks}',
                  label: '曲目',
                  icon: Icons.music_note_outlined,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: LekisSpacing.lg),
        Text('每月收听', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: LekisSpacing.sm),
        _BucketBars(
          buckets: summary.months,
          labelFor: (i) => '${i + 1}月',
          everyLabel: 2,
        ),
        const SizedBox(height: LekisSpacing.lg),
        Text('一天中的收听时段', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: LekisSpacing.sm),
        _BucketBars(
          buckets: summary.hours,
          labelFor: (i) => '$i',
          everyLabel: 4,
        ),
        const SizedBox(height: LekisSpacing.lg),
        if (summary.topArtists.isNotEmpty) ...[
          Text('最常听的艺人', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: LekisSpacing.sm),
          Card(
            child: Column(
              children: [
                for (final (i, a) in summary.topArtists.indexed)
                  ListTile(
                    leading: _Rank(index: i + 1),
                    title: Text(a.artist),
                    subtitle: Text('${a.plays} 次 · ${_formatHours(a.playedMs.toDouble() / 3600000)}'),
                    trailing: const Icon(Icons.chevron_right),
                  ),
              ],
            ),
          ),
          const SizedBox(height: LekisSpacing.lg),
        ],
        if (summary.topAlbums.isNotEmpty) ...[
          Text('最常听的专辑', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: LekisSpacing.sm),
          Card(
            child: Column(
              children: [
                for (final (i, a) in summary.topAlbums.indexed)
                  ListTile(
                    leading: _Rank(index: i + 1),
                    title: Text(a.title),
                    subtitle: Text(
                      '${a.artist.isEmpty ? '未知艺人' : a.artist} · ${a.plays} 次',
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: LekisSpacing.lg),
        ],
        if (summary.topTracks.isNotEmpty) ...[
          Text('最常听的曲目', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: LekisSpacing.sm),
          Card(
            child: Column(
              children: [
                for (final (i, item) in summary.topTracks.indexed)
                  ListTile(
                    leading: _Rank(index: i + 1),
                    title: Text(item.track.title),
                    subtitle: Text(
                      '${item.track.artistLine.isEmpty ? '未知艺人' : item.track.artistLine} · ${item.track.albumTitle ?? '未分类'}',
                    ),
                    trailing: Text('${item.plays} 次'),
                    onTap: () => _playFrom(context, ref, i),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  void _playFrom(BuildContext context, WidgetRef ref, int index) {
    final tracks = summary.topTracks.map((e) => e.track).toList();
    ref.read(playerActionsProvider).playRows(tracks, start: index);
    Navigator.of(context).pop();
  }
}

class _BigStat extends StatelessWidget {
  const _BigStat({required this.value, required this.label, required this.icon});

  final String value;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: Row(
        children: [
          Icon(icon, size: 22, color: context.lekisColors.moon),
          const SizedBox(width: LekisSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: Theme.of(context).textTheme.titleLarge),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: context.lekisColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Rank extends StatelessWidget {
  const _Rank({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final color = context.lekisColors.moon;
    return SizedBox(
      width: 28,
      child: Text(
        '$index',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color),
      ),
    );
  }
}

class _BucketBars extends StatelessWidget {
  const _BucketBars({
    required this.buckets,
    required this.labelFor,
    required this.everyLabel,
  });

  final List<ListeningBucketDto> buckets;
  final String Function(int index) labelFor;
  final int everyLabel;

  @override
  Widget build(BuildContext context) {
    final maxMs = buckets.fold<double>(
      0,
      (m, b) => b.playedMs.toDouble() > m ? b.playedMs.toDouble() : m,
    );
    final color = context.lekisColors.moon;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 14),
        child: SizedBox(
          height: 150,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (i, b) in buckets.indexed)
                Expanded(
                  child: Tooltip(
                    message:
                        '${labelFor(i)} · ${b.plays} 次 · ${_formatHours(b.playedMs.toDouble() / 3600000)}',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor: maxMs <= 0
                                    ? 0.02
                                    : (b.playedMs.toDouble() / maxMs)
                                          .clamp(0.02, 1.0),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: color.withValues(
                                      alpha: b.playedMs == BigInt.zero ? 0.18 : 0.8,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 14,
                            child: i % everyLabel == 0
                                ? Text(
                                    labelFor(i),
                                    style: Theme.of(context).textTheme.labelSmall
                                        ?.copyWith(
                                          color:
                                              context.lekisColors.onSurfaceVariant,
                                          fontSize: 9,
                                        ),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatHours(double hours) {
  if (hours <= 0) return '0 分钟';
  if (hours >= 1) {
    final whole = hours.floor();
    final minutes = ((hours - whole) * 60).round();
    return minutes == 0 ? '$whole 小时' : '$whole 小时 $minutes 分';
  }
  return '${(hours * 60).round()} 分钟';
}
