// DIS-06: listening statistics / year in review.
//
// The page intentionally uses only aggregate data from the core: a 100k-track
// library must not stream every play event into Dart.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/library_providers.dart'
    show artistIdForNameProvider;
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/sources/common.dart';
import 'package:lekis/src/features/stats/listening_stats_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/skeleton.dart';
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
      appBar: AppBar(title: Text(context.l10n.pick('听歌统计', 'Listening Stats'))),
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
              constraints: const BoxConstraints(
                maxWidth: featureMaxContentWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.pick(
                            '你的听歌足迹',
                            'Your Listening Footprint',
                          ),
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                      years.when(
                        data: (items) => DropdownButton<int?>(
                          value: _year,
                          hint: Text(context.l10n.pick('全部时间', 'All Time')),
                          items: [
                            DropdownMenuItem<int?>(
                              value: null,
                              child: Text(
                                context.l10n.pick('全部时间', 'All Time'),
                              ),
                            ),
                            for (final y in items)
                              DropdownMenuItem<int?>(
                                value: y,
                                child: Text(context.l10n.pick('$y 年', '$y')),
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
                    context.l10n.pick(
                      '统计来自本机播放记录；只在本地保存，不包含歌词或文件内容。',
                      'Based on local playback history; stored only on this device without lyrics or file contents.',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: LekisSpacing.lg),
                  summary.whenSkeleton(
                    skeleton: const _StatsSkeleton(),
                    error: (e, _) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.error_outline),
                        title: Text(
                          context.l10n.pick(
                            '读取听歌统计失败',
                            'Failed to load listening stats',
                          ),
                        ),
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

/// Loading layout of [_StatsBody]: totals card, two bar charts, top list.
class _StatsSkeleton extends StatelessWidget {
  const _StatsSkeleton();

  @override
  Widget build(BuildContext context) {
    const card = LekisRadius.md;
    Widget title(double width) => Padding(
      padding: const EdgeInsets.only(bottom: LekisSpacing.sm),
      child: LekisSkeleton.line(width: width, height: LekisSpacing.lg),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LekisSkeleton(height: 132, radius: card),
        const SizedBox(height: LekisSpacing.lg),
        title(72),
        // _BucketBars: 150 bars + 20 / 14 padding.
        const LekisSkeleton(height: 184, radius: card),
        const SizedBox(height: LekisSpacing.lg),
        title(112),
        const LekisSkeleton(height: 184, radius: card),
        const SizedBox(height: LekisSpacing.lg),
        title(96),
        for (var i = 0; i < 5; i++)
          SkeletonListTile(index: i, leadingSize: 40, circle: true),
      ],
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
            Text(
              context.l10n.pick('还没有听歌记录', 'No listening history yet'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: LekisSpacing.xs),
            Text(
              context.l10n.pick(
                '播放几首歌后，这里会显示听得最多的艺人、专辑和时段。',
                'Play a few tracks to see your top artists, albums, and listening hours.',
              ),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: context.lekisColors.onSurfaceVariant),
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
                  label: context.l10n.pick('累计收听', 'Total Time'),
                  icon: Icons.timer_outlined,
                ),
                _BigStat(
                  value: '${summary.totalPlays}',
                  label: context.l10n.pick('播放次数', 'Plays'),
                  icon: Icons.play_arrow_rounded,
                ),
                _BigStat(
                  value: '${summary.uniqueArtists}',
                  label: context.l10n.pick('艺人', 'Artists'),
                  icon: Icons.people_alt_outlined,
                ),
                _BigStat(
                  value: '${summary.uniqueAlbums}',
                  label: context.l10n.pick('专辑', 'Albums'),
                  icon: Icons.album_outlined,
                ),
                _BigStat(
                  value: '${summary.uniqueTracks}',
                  label: context.l10n.pick('曲目', 'Tracks'),
                  icon: Icons.music_note_outlined,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: LekisSpacing.lg),
        Text(
          context.l10n.pick('每月收听', 'Monthly Listening'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: LekisSpacing.sm),
        _BucketBars(
          buckets: summary.months,
          labelFor: (i) => context.l10n.pick(
            '${i + 1}月',
            const [
              'Jan',
              'Feb',
              'Mar',
              'Apr',
              'May',
              'Jun',
              'Jul',
              'Aug',
              'Sep',
              'Oct',
              'Nov',
              'Dec',
            ][i],
          ),
          everyLabel: 2,
        ),
        const SizedBox(height: LekisSpacing.lg),
        Text(
          context.l10n.pick('一天中的收听时段', 'Listening by Hour'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: LekisSpacing.sm),
        _BucketBars(
          buckets: summary.hours,
          labelFor: (i) => '$i',
          everyLabel: 4,
        ),
        const SizedBox(height: LekisSpacing.lg),
        if (summary.topArtists.isNotEmpty) ...[
          Text(
            context.l10n.pick('最常听的艺人', 'Top Artists'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Card(
            child: Column(
              children: [
                for (final (i, a) in summary.topArtists.indexed)
                  ListTile(
                    leading: _Rank(index: i + 1),
                    title: Text(a.artist),
                    subtitle: Text(
                      '${context.l10n.pick('${a.plays} 次', '${a.plays} plays')} · ${_formatHours(a.playedMs.toDouble() / 3600000)}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openArtist(context, ref, a.artist),
                  ),
              ],
            ),
          ),
          const SizedBox(height: LekisSpacing.lg),
        ],
        if (summary.topAlbums.isNotEmpty) ...[
          Text(
            context.l10n.pick('最常听的专辑', 'Top Albums'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Card(
            child: Column(
              children: [
                for (final (i, a) in summary.topAlbums.indexed)
                  ListTile(
                    leading: _Rank(index: i + 1),
                    title: Text(a.title),
                    subtitle: Text(
                      '${a.artist.isEmpty ? context.l10n.pick('未知艺人', 'Unknown Artist') : a.artist} · ${context.l10n.pick('${a.plays} 次', '${a.plays} plays')}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openAlbum(context, a),
                  ),
              ],
            ),
          ),
          const SizedBox(height: LekisSpacing.lg),
        ],
        if (summary.topTracks.isNotEmpty) ...[
          Text(
            context.l10n.pick('最常听的曲目', 'Top Tracks'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Card(
            child: Column(
              children: [
                for (final (i, item) in summary.topTracks.indexed)
                  ListTile(
                    leading: _Rank(index: i + 1),
                    title: Text(item.track.title),
                    subtitle: Text(
                      '${item.track.artistLine.isEmpty ? context.l10n.pick('未知艺人', 'Unknown Artist') : item.track.artistLine} · ${item.track.albumTitle ?? context.l10n.pick('未分类', 'Uncategorized')}',
                    ),
                    trailing: Text(
                      context.l10n.pick(
                        '${item.plays} 次',
                        '${item.plays} plays',
                      ),
                    ),
                    onTap: () => _playFrom(context, ref, i),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openArtist(
    BuildContext context,
    WidgetRef ref,
    String name,
  ) async {
    try {
      final id = await ref.read(artistIdForNameProvider(name).future);
      if (!context.mounted) return;
      if (id == null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.pick('资料库里没有这位艺人', 'Artist not found in library'),
              ),
            ),
          );
        return;
      }
      await Navigator.of(context).push(ArtistDetailPage.route(id));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick('打开艺人失败：$e', 'Failed to open artist: $e'),
            ),
          ),
        );
    }
  }

  Future<void> _openAlbum(BuildContext context, AlbumListeningDto album) async {
    try {
      final results = await core.search(text: album.title, limit: 20);
      AlbumDto? match;
      for (final candidate in results.albums) {
        if (candidate.title.toLowerCase() != album.title.toLowerCase()) {
          continue;
        }
        if (album.artist.isNotEmpty &&
            !candidate.artistLine.toLowerCase().contains(
              album.artist.toLowerCase(),
            )) {
          continue;
        }
        match = candidate;
        break;
      }
      if (!context.mounted) return;
      if (match == null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.pick('资料库里没有这张专辑', 'Album not found in library'),
              ),
            ),
          );
        return;
      }
      await Navigator.of(context).push(AlbumDetailPage.route(match.id.toInt()));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick('打开专辑失败：$e', 'Failed to open album: $e'),
            ),
          ),
        );
    }
  }

  void _playFrom(BuildContext context, WidgetRef ref, int index) {
    final tracks = summary.topTracks.map((e) => e.track).toList();
    ref.read(playerActionsProvider).playRows(tracks, start: index);
    Navigator.of(context).pop();
  }
}

class _BigStat extends StatelessWidget {
  const _BigStat({
    required this.value,
    required this.label,
    required this.icon,
  });

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
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: context.lekisColors.onSurfaceVariant),
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
                        '${labelFor(i)} · ${context.l10n.pick('${b.plays} 次', '${b.plays} plays')} · ${_formatHours(b.playedMs.toDouble() / 3600000)}',
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
                                    : (b.playedMs.toDouble() / maxMs).clamp(
                                        0.02,
                                        1.0,
                                      ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: color.withValues(
                                      alpha: b.playedMs == BigInt.zero
                                          ? 0.18
                                          : 0.8,
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
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: context
                                              .lekisColors
                                              .onSurfaceVariant,
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
  if (hours <= 0) return L10n.tr('0 分钟', '0m');
  if (hours >= 1) {
    final whole = hours.floor();
    final minutes = ((hours - whole) * 60).round();
    return minutes == 0
        ? L10n.tr('$whole 小时', '${whole}h')
        : L10n.tr('$whole 小时 $minutes 分', '${whole}h ${minutes}m');
  }
  final mins = (hours * 60).round();
  return L10n.tr('$mins 分钟', '${mins}m');
}
