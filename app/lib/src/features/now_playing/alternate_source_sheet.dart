import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/plugins/plugins_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/alternate_source.dart' as api;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:material_ui/material_ui.dart';

final _results = FutureProvider.autoDispose
    .family<
      List<api.AlternateSourceDto>,
      ({int track, String plugin, String query})
    >((ref, request) {
      return api.searchAlternateSources(
        trackId: request.track,
        pluginId: request.plugin,
        query: request.query,
      );
    });

Future<void> showAlternateSourceSheet(BuildContext context, TrackDto track) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _AlternateSourceSheet(track),
  );
}

class _AlternateSourceSheet extends ConsumerStatefulWidget {
  const _AlternateSourceSheet(this.track);
  final TrackDto track;

  @override
  ConsumerState<_AlternateSourceSheet> createState() => _AlternateSourceState();
}

class _AlternateSourceState extends ConsumerState<_AlternateSourceSheet> {
  late final _input = TextEditingController(text: widget.track.title);
  late String _query = _input.text;
  late final _saved = api.getAlternateSource(trackId: widget.track.id);
  int? _previewId;
  api.AlternateSourceDto? _selected;
  bool _busy = false;
  bool _finishing = false;
  String? _error;

  bool get _isCurrent => mounted && ModalRoute.of(context)?.isCurrent == true;

  Future<void> _audition(api.AlternateSourceDto candidate) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _cancel();
      if (!_isCurrent) return;
      final id = await api.previewAlternateSource(
        trackId: widget.track.id,
        candidate: candidate,
      );
      if (!_isCurrent) {
        await api.finishAlternateSourcePreview(previewId: id, remember: false);
        return;
      }
      _previewId = id;
      _selected = candidate;
    } catch (error) {
      _error = '$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final id = _previewId;
    if (id == null) return;
    _previewId = null;
    _selected = null;
    await api.finishAlternateSourcePreview(previewId: id, remember: false);
  }

  Future<void> _finish({bool reset = false, bool remember = false}) async {
    if (_busy) return;
    setState(() {
      _finishing = true;
      _busy = true;
    });
    try {
      if (remember) {
        await api.finishAlternateSourcePreview(
          previewId: _previewId!,
          remember: true,
        );
        _previewId = null;
      } else {
        await _cancel();
        if (reset) await api.resetAlternateSource(trackId: widget.track.id);
      }
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      await _cancel();
      if (mounted) {
        setState(() {
          _error = '$error';
          _busy = false;
          _finishing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    final id = _previewId;
    if (id != null) {
      unawaited(
        api
            .finishAlternateSourcePreview(previewId: id, remember: false)
            .catchError((Object _) {}),
      );
    }
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    ref.listen(playbackProvider.select((state) => state.trackId), (_, next) {
      if (next != widget.track.id &&
          ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    });
    void search() {
      if (_input.text.trim().isNotEmpty) {
        setState(() => _query = _input.text.trim());
      }
    }

    final sources = ref.watch(pluginListProvider);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.pick('手动换源', 'Change audio source'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              FutureBuilder(
                future: _saved,
                builder: (context, snapshot) {
                  final saved = snapshot.data;
                  if (snapshot.hasError) return Text('${snapshot.error}');
                  if (saved == null) return const SizedBox.shrink();
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.pick('已记住的音源', 'Saved source')),
                    subtitle: Text('${saved.title} · ${saved.pluginId}'),
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _finish(reset: true),
                      child: Text(l10n.pick('恢复默认', 'Use default')),
                    ),
                  );
                },
              ),
              TextField(
                controller: _input,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => search(),
                decoration: InputDecoration(
                  labelText: l10n.pick('歌名或艺人', 'Title or artist'),
                  suffixIcon: IconButton(
                    tooltip: l10n.pick('搜索', 'Search'),
                    onPressed: search,
                    icon: const Icon(Icons.search),
                  ),
                ),
              ),
              Expanded(
                child: sources.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Text('$error'),
                  data: (plugins) {
                    final enabled = plugins.where(
                      (p) =>
                          p.enabled &&
                          p.error == null &&
                          p.kinds.contains('source'),
                    );
                    if (enabled.isEmpty) {
                      return Center(
                        child: Text(
                          l10n.pick('没有启用的音源插件', 'No enabled source plugins'),
                        ),
                      );
                    }
                    return ListView(
                      children: [
                        for (final plugin in enabled)
                          Consumer(
                            builder: (context, ref, _) {
                              final request = (
                                track: widget.track.id,
                                plugin: plugin.id,
                                query: _query,
                              );
                              final candidates = ref.watch(_results(request));
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(
                                      plugin.name,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall,
                                    ),
                                  ),
                                  candidates.when(
                                    loading: () =>
                                        const LinearProgressIndicator(),
                                    error: (error, _) => TextButton(
                                      onPressed: () =>
                                          ref.invalidate(_results(request)),
                                      child: Text(
                                        l10n.pick(
                                          '搜索失败，重试',
                                          'Search failed. Retry',
                                        ),
                                      ),
                                    ),
                                    data: (rows) => rows.isEmpty
                                        ? Text(
                                            l10n.pick(
                                              '没有可播放的候选',
                                              'No playable matches',
                                            ),
                                          )
                                        : Column(
                                            children: [
                                              for (final row in rows)
                                                ListTile(
                                                  contentPadding:
                                                      EdgeInsets.zero,
                                                  title: Text(row.title),
                                                  subtitle: Text(row.artist),
                                                  trailing:
                                                      _selected?.pluginId ==
                                                              row.pluginId &&
                                                          _selected
                                                                  ?.externalId ==
                                                              row.externalId
                                                      ? Text(
                                                          l10n.pick(
                                                            '试听中',
                                                            'Previewing',
                                                          ),
                                                        )
                                                      : TextButton(
                                                          onPressed: _busy
                                                              ? null
                                                              : () => _audition(
                                                                  row,
                                                                ),
                                                          child: Text(
                                                            l10n.pick(
                                                              '试听',
                                                              'Preview',
                                                            ),
                                                          ),
                                                        ),
                                                ),
                                            ],
                                          ),
                                  ),
                                ],
                              );
                            },
                          ),
                      ],
                    );
                  },
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(_error!, maxLines: 2, overflow: TextOverflow.ellipsis),
              OverflowBar(
                children: [
                  TextButton(
                    onPressed: _finishing
                        ? null
                        : () {
                            if (_busy) {
                              Navigator.of(context).pop();
                            } else {
                              _finish();
                            }
                          },
                    child: Text(l10n.pick('取消', 'Cancel')),
                  ),
                  FilledButton(
                    onPressed: !_busy && _previewId != null
                        ? () => _finish(remember: true)
                        : null,
                    child: Text(l10n.pick('记住此音源', 'Remember source')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
