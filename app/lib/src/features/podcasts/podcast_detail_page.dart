// 节目详情（SRC-12）：封面、简介、订阅、单集列表（分页）。

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/podcasts/podcast_providers.dart';
import 'package:lekis/src/features/podcasts/podcast_strings.dart';
import 'package:lekis/src/features/podcasts/widgets/podcast_widgets.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/features/sources/common.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

class PodcastDetailPage extends ConsumerStatefulWidget {
  const PodcastDetailPage({super.key, this.podcastId, this.directory})
    : assert(podcastId != null || directory != null);

  /// 本地已有的节目。
  final int? podcastId;

  /// 从目录打开（需要先抓 RSS）。
  final DirectoryPodcastDto? directory;

  static Route<void> route({int? podcastId, DirectoryPodcastDto? directory}) =>
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/podcast'),
        builder: (_) =>
            PodcastDetailPage(podcastId: podcastId, directory: directory),
      );

  @override
  ConsumerState<PodcastDetailPage> createState() => _PodcastDetailPageState();
}

class _PodcastDetailPageState extends ConsumerState<PodcastDetailPage> {
  int? _id;
  Object? _openError;
  bool _busy = false;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _id = widget.podcastId;
    if (_id == null) _open();
  }

  Future<void> _open() async {
    final directory = widget.directory;
    if (directory == null) return;
    setState(() => _openError = null);
    try {
      final podcast = await ref
          .read(podcastActionsProvider)
          .openDirectory(directory);
      if (!mounted) return;
      ref.invalidate(podcastDetailProvider(podcast.id));
      ref.invalidate(podcastEpisodesProvider(podcast.id));
      setState(() => _id = podcast.id);
    } catch (e) {
      if (mounted) setState(() => _openError = e);
    }
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (done != null && mounted) showFeatureSnack(context, done);
    } catch (e) {
      if (mounted) {
        showFeatureSnack(
          context,
          '${PodcastStrings.actionFailed}：${describeCoreError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = _id;
    final title = id == null
        ? (widget.directory?.title ?? PodcastStrings.title)
        : (ref.watch(podcastDetailProvider(id)).value?.title ??
              widget.directory?.title ??
              PodcastStrings.title);
    return SettingsScaffold(
      title: title,
      actions: [
        if (id != null) ...[
          IconButton(
            tooltip: PodcastStrings.refresh,
            onPressed: _busy
                ? null
                : () =>
                      _run(() => ref.read(podcastActionsProvider).refresh(id)),
            icon: const Icon(Icons.refresh_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: PodcastStrings.more,
            onSelected: (value) {
              if (value == 'all-played') {
                _run(() => ref.read(podcastActionsProvider).markAllPlayed(id));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'all-played',
                child: Text(PodcastStrings.markAllPlayed),
              ),
            ],
          ),
        ],
      ],
      body: id == null ? _buildOpening(context) : _buildBody(context, id),
    );
  }

  Widget _buildOpening(BuildContext context) {
    final error = _openError;
    if (error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LekisEmptyState(
      eyebrow: PodcastStrings.eyebrow,
      title: PodcastStrings.loadFailed,
      message: '${describeCoreError(error)}\n${PodcastStrings.networkHint}',
      maxWidth: 460,
      action: FilledButton.icon(
        onPressed: _open,
        icon: const Icon(Icons.refresh_rounded),
        label: Text(PodcastStrings.retry),
      ),
    );
  }

  Widget _buildBody(BuildContext context, int id) {
    final detail = ref.watch(podcastDetailProvider(id));
    final episodes = ref.watch(podcastEpisodesProvider(id));
    final currentTrackId = ref.watch(podcastNowPlayingTrackIdProvider);
    final gutter = pageGutterOf(context);

    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            final state = episodes.value;
            if (n.metrics.extentAfter < 400 &&
                state != null &&
                state.hasMore &&
                !state.loadingMore) {
              ref.read(podcastEpisodesProvider(id).notifier).loadMore();
            }
            return false;
          },
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    0,
                    gutter,
                    LekisSpacing.md,
                  ),
                  child: detail.when(
                    loading: () => const SizedBox(
                      height: 120,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (e, _) => Text(describeCoreError(e)),
                    data: (podcast) => _Header(
                      podcast: podcast,
                      busy: _busy,
                      expanded: _expanded,
                      onToggleExpanded: () =>
                          setState(() => _expanded = !_expanded),
                      onToggleSubscribe: () => _run(
                        () => ref
                            .read(podcastActionsProvider)
                            .setSubscribed(podcast.id, !podcast.subscribed),
                        done: podcast.subscribed
                            ? PodcastStrings.unsubscribedDone
                            : PodcastStrings.subscribedDone,
                      ),
                    ),
                  ),
                ),
              ),
              ...episodes.when(
                loading: () => const [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(LekisSpacing.xl),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
                ],
                error: (e, _) => [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(gutter),
                      child: Text(describeCoreError(e)),
                    ),
                  ),
                ],
                data: (state) {
                  if (state.episodes.isEmpty) {
                    return [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(gutter),
                          child: Text(PodcastStrings.episodesEmpty),
                        ),
                      ),
                    ];
                  }
                  return [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        gutter - LekisSpacing.sm,
                        0,
                        gutter - LekisSpacing.sm,
                        scrollEndPadding(context),
                      ),
                      sliver: SliverList.builder(
                        itemCount:
                            state.episodes.length + (state.hasMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= state.episodes.length) {
                            return const Padding(
                              padding: EdgeInsets.all(LekisSpacing.lg),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          final episode = state.episodes[index];
                          return PodcastEpisodeTile(
                            episode: episode,
                            playing: currentTrackId == episode.trackId,
                            showArtwork: false,
                            onPlay: () => _run(
                              () => ref.read(podcastActionsProvider).play([
                                episode,
                              ], 0),
                            ),
                            onTogglePlayed: () => _run(
                              () => ref
                                  .read(podcastActionsProvider)
                                  .setPlayed(episode, !episode.played),
                            ),
                          );
                        },
                      ),
                    ),
                  ];
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.podcast,
    required this.busy,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onToggleSubscribe,
  });

  final PodcastDto podcast;
  final bool busy;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onToggleSubscribe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final meta = [
      if (podcast.author?.isNotEmpty == true) podcast.author!,
      if (podcast.categories.isNotEmpty) podcast.categories.first,
      PodcastStrings.episodeCount(podcast.episodeCount),
    ].join(' · ');
    final description = podcast.description;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PodcastArtwork(
              url: podcast.artworkUrl,
              size: 112,
              radius: LekisRadius.artworkGrid,
            ),
            const SizedBox(width: LekisSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    meta,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: LekisSpacing.md),
                  Wrap(
                    spacing: LekisSpacing.sm,
                    runSpacing: LekisSpacing.sm,
                    children: [
                      if (podcast.subscribed)
                        OutlinedButton.icon(
                          onPressed: busy ? null : onToggleSubscribe,
                          icon: const Icon(Icons.check_rounded),
                          label: Text(PodcastStrings.subscribed),
                        )
                      else
                        FilledButton.icon(
                          onPressed: busy ? null : onToggleSubscribe,
                          icon: const Icon(Icons.add_rounded),
                          label: Text(PodcastStrings.subscribe),
                        ),
                      IconButton(
                        tooltip: 'RSS',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: podcast.feedUrl),
                          );
                          if (context.mounted) {
                            showFeatureSnack(
                              context,
                              PodcastStrings.linkCopied,
                            );
                          }
                        },
                        icon: const Icon(Icons.rss_feed_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (podcast.lastError != null) ...[
          const SizedBox(height: LekisSpacing.sm),
          Text(
            PodcastStrings.lastError(podcast.lastError!),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        if (description != null && description.isNotEmpty) ...[
          const SizedBox(height: LekisSpacing.md),
          InkWell(
            onTap: onToggleExpanded,
            borderRadius: BorderRadius.circular(LekisRadius.sm),
            child: Text(
              description,
              maxLines: expanded ? null : 3,
              overflow: expanded ? null : TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
        const SizedBox(height: LekisSpacing.md),
        Text(PodcastStrings.episodes, style: theme.textTheme.titleMedium),
      ],
    );
  }
}
