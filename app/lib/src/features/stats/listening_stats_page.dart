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
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/features/sources/common.dart';
import 'package:lekis/src/features/stats/listening_stats_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/mascot.dart';
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

    return SettingsScaffold(
      title: context.l10n.pick('听歌统计', 'Listening Stats'),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(listeningYearsProvider);
          ref.invalidate(listeningSummaryProvider(_year));
          await ref.read(listeningSummaryProvider(_year).future);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            pageGutterOf(context),
            LekisSpacing.sm,
            pageGutterOf(context),
            scrollEndPadding(context),
          ),
          children: [
            Align(
              alignment: AlignmentDirectional.topStart,
              child: ConstrainedBox(
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
                            context.l10n.pick('时间范围', 'Time range'),
                            style: theme.textTheme.bodyLarge,
                          ),
                        ),
                        years.when(
                          data: (items) => Flexible(
                            child: SettingsSelectField<int?>(
                              title: context.l10n.pick('时间范围', 'Time range'),
                              icon: Icons.calendar_month_outlined,
                              value: _year,
                              choices: [
                                SettingsChoice(
                                  null,
                                  context.l10n.pick('全部时间', 'All Time'),
                                ),
                                for (final y in items)
                                  SettingsChoice(
                                    y,
                                    context.l10n.pick('$y 年', '$y'),
                                  ),
                              ],
                              onChanged: (year) => setState(() => _year = year),
                            ),
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
        const LekisSkeleton(height: 144, radius: card),
        const SizedBox(height: LekisSpacing.lg),
        title(112),
        const LekisSkeleton(height: 144, radius: card),
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
            const LekisMascot(pose: LekisMascotPose.sitting, size: 112),
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
        SizedBox(
          width: double.infinity,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.lekisColors.surfaceVariant,
              borderRadius: BorderRadius.circular(LekisRadius.md),
            ),
            child: Padding(
              padding: const EdgeInsets.all(LekisSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.pick('累计收听', 'Total time'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: LekisSpacing.xs),
                  Text(
                    _formatHours(hours),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: LekisSpacing.lg),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final minWidth = MediaQuery.textScalerOf(context)
                          .scale(72);
                      final columns = constraints.maxWidth >= 4 * minWidth
                          ? 4
                          : constraints.maxWidth >= 2 * minWidth
                          ? 2
                          : 1;
                      return Wrap(
                        runSpacing: LekisSpacing.md,
                        children: [
                          for (final (value, label) in [
                            (
                              summary.totalPlays,
                              context.l10n.pick('播放次数', 'Plays'),
                            ),
                            (
                              summary.uniqueArtists,
                              context.l10n.pick('艺人', 'Artists'),
                            ),
                            (
                              summary.uniqueAlbums,
                              context.l10n.pick('专辑', 'Albums'),
                            ),
                            (
                              summary.uniqueTracks,
                              context.l10n.pick('曲目', 'Tracks'),
                            ),
                          ])
                            SizedBox(
                              width: constraints.maxWidth / columns,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$value',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  Text(
                                    label,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
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
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.pick('最常听的曲目', 'Top Tracks'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: context.l10n.pick('播放全部', 'Play all'),
                onPressed: () => _playAll(context, ref),
                icon: const Icon(Icons.play_arrow_rounded),
              ),
              IconButton(
                tooltip: context.l10n.pick('随机播放', 'Shuffle'),
                onPressed: () => _playAll(context, ref, shuffle: true),
                icon: const Icon(Icons.shuffle_rounded),
              ),
            ],
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

  void _playAll(BuildContext context, WidgetRef ref, {bool shuffle = false}) {
    final tracks = summary.topTracks
        .map((item) => item.track)
        .toList(growable: false);
    if (tracks.isEmpty) return;
    ref.read(playerActionsProvider).playRows(tracks, shuffle: shuffle);
    Navigator.of(context).pop();
  }

  void _playFrom(BuildContext context, WidgetRef ref, int index) {
    final tracks = summary.topTracks.map((e) => e.track).toList();
    ref.read(playerActionsProvider).playRows(tracks, start: index);
    Navigator.of(context).pop();
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
    final tickStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: context.lekisColors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
      child: Column(
        children: [
          SizedBox(
            height: 112,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (i, bucket) in buckets.indexed)
                  Expanded(
                    child: Tooltip(
                      message:
                          '${labelFor(i)} · ${context.l10n.pick('${bucket.plays} 次', '${bucket.plays} plays')} · ${_formatHours(bucket.playedMs.toDouble() / 3600000)}',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: LekisSpacing.xxs,
                        ),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            heightFactor: maxMs == 0
                                ? 0
                                : bucket.playedMs.toDouble() / maxMs,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(LekisRadius.xs),
                                ),
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: LekisSpacing.xs),
          Row(
            children: [
              for (var i = 0; i < buckets.length; i += everyLabel)
                Expanded(
                  flex: (buckets.length - i).clamp(1, everyLabel),
                  child: Text(labelFor(i), style: tickStyle),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _formatHours(double hours) {
  final total = (hours * 60).round();
  if (total < 60) return L10n.tr('$total 分钟', '${total}m');
  final whole = total ~/ 60;
  final minutes = total % 60;
  return minutes == 0
      ? L10n.tr('$whole 小时', '${whole}h')
      : L10n.tr('$whole 小时 $minutes 分', '${whole}h ${minutes}m');
}
