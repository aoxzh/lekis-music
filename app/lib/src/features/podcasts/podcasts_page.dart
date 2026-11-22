// 播客页面（SRC-12）：订阅（继续收听 / 我的订阅 / 最新单集）和发现（搜索 / 分地区排行榜）。
//
// 目录来自 Apple Podcasts（免密钥），节目和单集直接读节目自己的 RSS。
// 网络电台（SRC-11）作为次级入口保留在右上角菜单里。

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/podcasts/podcast_detail_page.dart';
import 'package:lekis/src/features/podcasts/podcast_providers.dart';
import 'package:lekis/src/features/podcasts/podcast_strings.dart';
import 'package:lekis/src/features/podcasts/widgets/podcast_widgets.dart';
import 'package:lekis/src/features/radio/radio_page.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/features/sources/common.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

enum PodcastTab { subscriptions, discover }

class PodcastsPage extends ConsumerStatefulWidget {
  const PodcastsPage({super.key, this.initialTab = PodcastTab.subscriptions});

  final PodcastTab initialTab;

  @override
  ConsumerState<PodcastsPage> createState() => _PodcastsPageState();
}

class _PodcastsPageState extends ConsumerState<PodcastsPage> {
  late PodcastTab _tab = widget.initialTab;
  final _search = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (mounted) showFeatureSnack(context, message);
  }

  void _fail(Object e) =>
      _snack('${PodcastStrings.actionFailed}：${describeCoreError(e)}');

  void _openLocal(int id) =>
      Navigator.of(context).push<void>(PodcastDetailPage.route(podcastId: id));

  void _openDirectory(DirectoryPodcastDto podcast) {
    Navigator.of(context).push<void>(
      podcast.localId != null && podcast.subscribed
          ? PodcastDetailPage.route(podcastId: podcast.localId)
          : PodcastDetailPage.route(directory: podcast),
    );
  }

  Future<void> _refreshAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(podcastActionsProvider).refreshAll();
      _snack(
        PodcastStrings.refreshReport(r.refreshed, r.failed, r.newEpisodes),
      );
    } catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addByUrl() async {
    final address = await showDialog<String>(
      context: context,
      builder: (_) => const _AddFeedDialog(),
    );
    if (address == null || address.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final podcast = await ref
          .read(podcastActionsProvider)
          .openFeed(address.trim());
      if (!mounted) return;
      ref.invalidate(podcastDetailProvider(podcast.id));
      ref.invalidate(podcastEpisodesProvider(podcast.id));
      _openLocal(podcast.id);
    } catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importOpml() async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: PodcastStrings.importOpml,
        type: FileType.custom,
        allowedExtensions: const ['opml', 'xml'],
      );
      if (file == null || !mounted) return;
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      setState(() => _busy = true);
      final r = await ref.read(podcastActionsProvider).importOpml(text);
      _snack(
        PodcastStrings.importReport(r.added, r.alreadySubscribed, r.failed),
      );
      if (mounted) setState(() => _tab = PodcastTab.subscriptions);
    } catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportOpml() async {
    const name = 'lekis-podcasts.opml';
    try {
      final text = await ref.read(podcastActionsProvider).exportOpml();
      final saved = await FilePicker.saveFile(
        dialogTitle: PodcastStrings.exportOpml,
        fileName: name,
        bytes: Uint8List.fromList(utf8.encode(text)),
        mimeType: 'text/x-opml',
      );
      if (saved != null) _snack(PodcastStrings.exported(name));
    } catch (e) {
      _fail(e);
    }
  }

  void _submitSearch([String? value]) {
    ref.read(podcastSearchTermProvider.notifier).set(value ?? _search.text);
  }

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutterOf(context);
    return SettingsScaffold(
      title: PodcastStrings.title,
      actions: [
        IconButton(
          tooltip: PodcastStrings.refreshAll,
          onPressed: _busy ? null : _refreshAll,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: PodcastStrings.addByUrl,
          onPressed: _busy ? null : _addByUrl,
          icon: const Icon(Icons.add_link_rounded),
        ),
        PopupMenuButton<String>(
          tooltip: PodcastStrings.more,
          onSelected: (value) {
            switch (value) {
              case 'import':
                _importOpml();
              case 'export':
                _exportOpml();
              case 'radio':
                Navigator.of(context).push<void>(RadioPage.route());
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'import',
              child: ListTile(
                leading: Icon(Icons.file_download_outlined),
                title: Text(PodcastStrings.importOpml),
              ),
            ),
            PopupMenuItem(
              value: 'export',
              child: ListTile(
                leading: Icon(Icons.file_upload_outlined),
                title: Text(PodcastStrings.exportOpml),
              ),
            ),
            PopupMenuDivider(),
            PopupMenuItem(
              value: 'radio',
              child: ListTile(
                leading: Icon(Icons.radio_rounded),
                title: Text(PodcastStrings.radio),
              ),
            ),
          ],
        ),
      ],
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  0,
                  gutter,
                  LekisSpacing.sm,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<PodcastTab>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: PodcastTab.subscriptions,
                        label: Text(PodcastStrings.tabSubscriptions),
                        icon: Icon(Icons.subscriptions_outlined),
                      ),
                      ButtonSegment(
                        value: PodcastTab.discover,
                        label: Text(PodcastStrings.tabDiscover),
                        icon: Icon(Icons.explore_outlined),
                      ),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (s) => setState(() => _tab = s.first),
                  ),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: LekisMotion.fast,
                  child: KeyedSubtree(
                    key: ValueKey(_tab),
                    child: _tab == PodcastTab.subscriptions
                        ? _SubscriptionsView(
                            onOpen: _openLocal,
                            onDiscover: () =>
                                setState(() => _tab = PodcastTab.discover),
                            onImport: _importOpml,
                            onError: _fail,
                          )
                        : _DiscoverView(
                            search: _search,
                            onSubmit: _submitSearch,
                            onOpen: _openDirectory,
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

// ---------------------------------------------------------------------------
// 订阅
// ---------------------------------------------------------------------------

class _SubscriptionsView extends ConsumerWidget {
  const _SubscriptionsView({
    required this.onOpen,
    required this.onDiscover,
    required this.onImport,
    required this.onError,
  });

  final ValueChanged<int> onOpen;
  final VoidCallback onDiscover;
  final VoidCallback onImport;
  final ValueChanged<Object> onError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(podcastSubscriptionsProvider);
    final inProgress = ref.watch(podcastInProgressProvider).value ?? const [];
    final latest = ref.watch(podcastLatestProvider).value ?? const [];
    final currentTrackId = ref.watch(podcastNowPlayingTrackIdProvider);
    final gutter = pageGutterOf(context);

    Future<void> act(Future<void> Function() f) async {
      try {
        await f();
      } catch (e) {
        onError(e);
      }
    }

    Widget episodeTile(PodcastEpisodeDto e, {required bool showPodcast}) =>
        PodcastEpisodeTile(
          episode: e,
          playing: currentTrackId == e.trackId,
          showPodcastTitle: showPodcast,
          onPlay: () =>
              act(() => ref.read(podcastActionsProvider).play([e], 0)),
          onTogglePlayed: () => act(
            () => ref.read(podcastActionsProvider).setPlayed(e, !e.played),
          ),
        );

    return subs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorState(
        error: e,
        onRetry: () => ref.invalidate(podcastSubscriptionsProvider),
      ),
      data: (list) {
        if (list.isEmpty && inProgress.isEmpty) {
          return LekisEmptyState(
            eyebrow: PodcastStrings.eyebrow,
            title: PodcastStrings.subscriptionsEmpty,
            message: PodcastStrings.subscriptionsEmptyBody,
            maxWidth: 460,
            action: Wrap(
              spacing: LekisSpacing.sm,
              runSpacing: LekisSpacing.sm,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: onDiscover,
                  icon: const Icon(Icons.explore_rounded),
                  label: Text(PodcastStrings.goDiscover),
                ),
                OutlinedButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.file_download_outlined),
                  label: Text(PodcastStrings.importOpml),
                ),
              ],
            ),
          );
        }
        final inset = EdgeInsets.symmetric(
          horizontal: gutter - LekisSpacing.sm,
        );
        return RefreshIndicator(
          onRefresh: () async {
            try {
              await ref.read(podcastActionsProvider).refreshAll();
            } catch (e) {
              onError(e);
            }
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (inProgress.isNotEmpty) ...[
                _SectionHeader(PodcastStrings.continueListening, gutter),
                SliverPadding(
                  padding: inset,
                  sliver: SliverList.list(
                    children: [
                      for (final e in inProgress.take(5))
                        episodeTile(e, showPodcast: true),
                    ],
                  ),
                ),
              ],
              if (list.isNotEmpty) ...[
                _SectionHeader(PodcastStrings.mySubscriptions, gutter),
                SliverPadding(
                  padding: inset,
                  sliver: SliverList.list(
                    children: [
                      for (final p in list)
                        SubscribedPodcastTile(
                          podcast: p,
                          onTap: () => onOpen(p.id),
                        ),
                    ],
                  ),
                ),
              ],
              if (latest.isNotEmpty) ...[
                _SectionHeader(PodcastStrings.latestEpisodes, gutter),
                SliverPadding(
                  padding: inset,
                  sliver: SliverList.list(
                    children: [
                      for (final e in latest) episodeTile(e, showPodcast: true),
                    ],
                  ),
                ),
              ],
              SliverToBoxAdapter(
                child: SizedBox(height: scrollEndPadding(context)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, this.gutter);
  final String title;
  final double gutter;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.md,
        gutter,
        LekisSpacing.xs,
      ),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}

// ---------------------------------------------------------------------------
// 发现
// ---------------------------------------------------------------------------

class _DiscoverView extends ConsumerWidget {
  const _DiscoverView({
    required this.search,
    required this.onSubmit,
    required this.onOpen,
  });

  final TextEditingController search;
  final ValueChanged<String?> onSubmit;
  final ValueChanged<DirectoryPodcastDto> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gutter = pageGutterOf(context);
    final term = ref.watch(podcastSearchTermProvider);
    final region = ref.watch(podcastRegionProvider);
    final genre = ref.watch(podcastGenreProvider);
    final results = term.isEmpty
        ? ref.watch(podcastTopProvider)
        : ref.watch(podcastSearchProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, LekisSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: search,
                  builder: (context, value, _) => TextField(
                    controller: search,
                    textInputAction: TextInputAction.search,
                    onSubmitted: onSubmit,
                    decoration: InputDecoration(
                      hintText: PodcastStrings.searchHint,
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: value.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: PodcastStrings.clear,
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                search.clear();
                                onSubmit('');
                              },
                            ),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: LekisSpacing.sm),
              _RegionPicker(
                value: region,
                onChanged: (r) =>
                    ref.read(podcastRegionProvider.notifier).set(r),
              ),
            ],
          ),
        ),
        if (term.isEmpty)
          SizedBox(
            height: LekisSizes.touchTargetMin,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: gutter),
              children: [
                for (final (id, label) in [
                  (null, PodcastStrings.allGenres),
                  ...podcastGenres,
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: LekisSpacing.xs),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: genre == id,
                      onSelected: (_) =>
                          ref.read(podcastGenreProvider.notifier).set(id),
                    ),
                  ),
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            LekisSpacing.sm,
            gutter,
            LekisSpacing.xs,
          ),
          child: Text(
            term.isEmpty
                ? PodcastStrings.topCharts
                : PodcastStrings.searchResults,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: results.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _ErrorState(
              error: e,
              onRetry: () => ref.invalidate(
                term.isEmpty ? podcastTopProvider : podcastSearchProvider,
              ),
            ),
            data: (list) {
              if (list.isEmpty) {
                return LekisEmptyState(
                  eyebrow: PodcastStrings.eyebrow,
                  title: term.isEmpty
                      ? PodcastStrings.chartEmpty
                      : PodcastStrings.searchEmpty,
                  message: term.isEmpty ? '' : PodcastStrings.searchEmptyBody,
                  maxWidth: 460,
                );
              }
              return ListView.builder(
                padding: EdgeInsets.fromLTRB(
                  gutter - LekisSpacing.sm,
                  0,
                  gutter - LekisSpacing.sm,
                  scrollEndPadding(context),
                ),
                itemCount: list.length,
                itemBuilder: (context, index) => DirectoryPodcastTile(
                  podcast: list[index],
                  rank: term.isEmpty ? index + 1 : null,
                  onTap: () => onOpen(list[index]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RegionPicker extends StatelessWidget {
  const _RegionPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = podcastRegions
        .firstWhere((r) => r.$1 == value, orElse: () => (value, value))
        .$2;
    return PopupMenuButton<String>(
      tooltip: PodcastStrings.region,
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final (code, name) in podcastRegions)
          PopupMenuItem(value: code, child: Text(name)),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: LekisSizes.touchTargetMin),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.public_rounded, size: 20),
              const SizedBox(width: LekisSpacing.xs),
              Text(label),
              const Icon(Icons.arrow_drop_down_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddFeedDialog extends StatefulWidget {
  const _AddFeedDialog();

  @override
  State<_AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends State<_AddFeedDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(PodcastStrings.addByUrl),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: PodcastStrings.addByUrlHint,
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        const SizedBox(height: LekisSpacing.sm),
        Text(
          PodcastStrings.addByUrlBody,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(PodcastStrings.cancel),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: Text(PodcastStrings.add),
      ),
    ],
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => LekisEmptyState(
    eyebrow: PodcastStrings.eyebrow,
    title: PodcastStrings.loadFailed,
    message: '${describeCoreError(error)}\n${PodcastStrings.networkHint}',
    maxWidth: 460,
    action: FilledButton.icon(
      onPressed: onRetry,
      icon: const Icon(Icons.refresh_rounded),
      label: Text(PodcastStrings.retry),
    ),
  );
}
