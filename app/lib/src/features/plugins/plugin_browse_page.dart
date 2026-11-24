import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';
import '../../theme/tokens.dart';
import '../library/widgets/empty_state.dart';
import '../library/widgets/page_gutter.dart';
import '../library/widgets/track_tile.dart';
import '../player/player_providers.dart';
import '../sources/common.dart';
import 'collection_subscriptions.dart';

typedef PluginBrowseRequest = ({String pluginId, String path, String? cursor});

final pluginBrowseProvider = FutureProvider.autoDispose
    .family<PluginBrowsePageDto, PluginBrowseRequest>(
      (ref, request) => core.browsePlugin(
        pluginId: request.pluginId,
        path: request.path,
        cursor: request.cursor,
      ),
      retry: (_, _) => null,
    );

/// Source collections use the same track rows and queue actions as local music.
class PluginBrowsePage extends ConsumerStatefulWidget {
  const PluginBrowsePage({
    super.key,
    required this.pluginId,
    required this.title,
    this.path = '',
  });
  final String pluginId;
  final String title;
  final String path;

  static Route<void> route(String pluginId, String title, {String path = ''}) =>
      MaterialPageRoute<void>(
        builder: (_) =>
            PluginBrowsePage(pluginId: pluginId, title: title, path: path),
      );

  @override
  ConsumerState<PluginBrowsePage> createState() => _PluginBrowsePageState();
}

class _PluginBrowsePageState extends ConsumerState<PluginBrowsePage> {
  final _folders = <PluginFolderDto>[];
  final _tracks = <TrackRowDto>[];
  final _loadedCursors = <String>{};
  String? _cursor;
  bool _loadingMore = false;
  Object? _moreError;
  int _generation = 0;

  PluginBrowseRequest get _request =>
      (pluginId: widget.pluginId, path: widget.path, cursor: null);

  Future<void> _more(String cursor) async {
    final generation = _generation;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final provider = pluginBrowseProvider((
        pluginId: widget.pluginId,
        path: widget.path,
        cursor: cursor,
      ));
      ref.invalidate(provider);
      final page = await ref.read(provider.future);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadedCursors.add(cursor);
        _folders.addAll(page.folders);
        _tracks.addAll(page.tracks);
        _cursor = page.next;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _moreError = error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingMore = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(pluginBrowseProvider(_request));
    final page = loaded.value;
    final l10n = context.l10n;
    final gutter = pageGutterOf(context);
    final saved = widget.path.isEmpty
        ? null
        : ref.watch(collectionSubscriptionsProvider);
    final subscribed =
        saved?.value?.any(
          (row) => row.plugin == widget.pluginId && row.path == widget.path,
        ) ??
        false;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.path.isNotEmpty)
            IconButton(
              tooltip: subscribed
                  ? l10n.pick('取消订阅', 'Unsubscribe')
                  : l10n.pick('订阅', 'Subscribe'),
              icon: Icon(subscribed ? Icons.bookmark : Icons.bookmark_border),
              onPressed: saved?.hasValue == true && (subscribed || page != null)
                  ? () async {
                      try {
                        await ref
                            .read(collectionSubscriptionsProvider.notifier)
                            .setSubscribed((
                              plugin: widget.pluginId,
                              path: widget.path,
                              title: widget.title,
                            ), !subscribed);
                      } catch (error) {
                        if (context.mounted) {
                          showFeatureSnack(context, describeCoreError(error));
                        }
                      }
                    }
                  : null,
            ),
          IconButton(
            tooltip: l10n.pick('刷新目录', 'Refresh collection'),
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _generation++;
                _folders.clear();
                _tracks.clear();
                _loadedCursors.clear();
                _cursor = null;
                _loadingMore = false;
                _moreError = null;
              });
              ref.invalidate(pluginBrowseProvider(_request));
            },
          ),
        ],
      ),
      body: page == null
          ? loaded.hasError
                ? LoadErrorView(
                    error: loaded.error!,
                    onRetry: () =>
                        ref.invalidate(pluginBrowseProvider(_request)),
                  )
                : const Center(child: CircularProgressIndicator())
          : Builder(
              builder: (context) {
                final folders = {
                  for (final item in [...page.folders, ..._folders])
                    item.id: item,
                }.values.toList();
                final tracks = {
                  for (final item in [...page.tracks, ..._tracks])
                    item.id: item,
                }.values.toList();
                final next = _loadedCursors.isEmpty ? page.next : _cursor;
                if (folders.isEmpty && tracks.isEmpty && next == null) {
                  return LekisEmptyState(
                    title: l10n.pick('暂无内容', 'No music here yet'),
                  );
                }
                return ListView(
                  padding: EdgeInsets.fromLTRB(
                    gutter - LekisSpacing.sm,
                    LekisSpacing.sm,
                    gutter - LekisSpacing.sm,
                    scrollEndPadding(context),
                  ),
                  children: [
                    for (final folder in folders)
                      ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder.title),
                        subtitle: folder.subtitle == null
                            ? null
                            : Text(folder.subtitle!),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(
                          PluginBrowsePage.route(
                            widget.pluginId,
                            folder.title,
                            path: folder.id,
                          ),
                        ),
                      ),
                    for (var i = 0; i < tracks.length; i++)
                      TrackTile(
                        track: tracks[i],
                        onlinePlugin: true,
                        pluginId: widget.pluginId,
                        onTap: () => ref
                            .read(playerActionsProvider)
                            .playRows(tracks, start: i),
                      ),
                    if (_moreError != null)
                      Padding(
                        padding: const EdgeInsets.all(LekisSpacing.sm),
                        child: Text(
                          describeCoreError(_moreError!),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (next != null && !_loadedCursors.contains(next))
                      Center(
                        child: TextButton(
                          onPressed: _loadingMore ? null : () => _more(next),
                          child: _loadingMore
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(l10n.pick('加载更多', 'Load more')),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
