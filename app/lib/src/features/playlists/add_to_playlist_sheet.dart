// "添加到歌单"选择器：从曲目行 / 正在播放 / 队列打开。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/progress_dialog.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lekis/src/features/playlists/playlist_strings.dart';

class _AddResult {
  const _AddResult(this.playlistName, {required this.created});
  final String playlistName;
  final bool created;
}

class _PickerData {
  const _PickerData({required this.track, required this.playlists});
  final TrackDto track;
  final List<PlaylistDto> playlists;
}

/// 打开选择器。`context` 用于关闭后的 SnackBar。
Future<void> showAddToPlaylistSheet(
  BuildContext context, {
  required int trackId,
  String? trackTitle,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await showLekisSheet<_AddResult>(
    context,
    heightFactor: null,
    builder: (sheet) => _PlaylistPickerFrame(
      child: AddToPlaylistSheet(trackId: trackId, trackTitle: trackTitle),
    ),
  );
  if (result == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          result.created
              ? PlaylistStrings.createdAndAdded(result.playlistName)
              : PlaylistStrings.addedTo(result.playlistName),
        ),
      ),
    );
}

/// 多选：选择一张歌单后把 [trackIds] 全部加入，返回是否至少添加了一首。
Future<bool> showAddTracksToPlaylistSheet(
  BuildContext context,
  WidgetRef ref, {
  required List<int> trackIds,
}) async {
  if (trackIds.isEmpty) return false;
  // The same track can appear several times (playback history, playlists
  // with repeats); add each track once.
  final uniqueIds = <int>[];
  final seenIds = <int>{};
  for (final id in trackIds) {
    if (seenIds.add(id)) uniqueIds.add(id);
  }
  final total = uniqueIds.length;
  final playlist = await showLekisSheet<PlaylistDto>(
    context,
    heightFactor: null,
    builder: (_) =>
        _PlaylistPickerFrame(child: _AddTracksPlaylistPicker(count: total)),
  );
  if (playlist == null || !context.mounted) return false;

  final progress = ValueNotifier<int>(0);
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => nonDismissibleProgressDialog(
        title: Text(PlaylistStrings.addingTracks),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, done, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: total == 0 ? 0 : (done / total).clamp(0.0, 1.0),
              ),
              const SizedBox(height: LekisSpacing.md),
              Text('$done / $total'),
            ],
          ),
        ),
      ),
    ),
  );

  var added = 0;
  var already = 0;
  var failed = 0;
  try {
    // Read the playlist's uids once instead of scanning it per track; if the
    // read fails, keep going without the duplicate check.
    final existing = <String>{};
    try {
      var offset = 0;
      while (true) {
        final rows = await core.playlistItems(
          playlistId: playlist.id,
          offset: offset,
          limit: 500,
        );
        if (rows.isEmpty) break;
        existing.addAll([for (final row in rows) row.trackUid]);
        offset += rows.length;
        if (rows.length < 500) break;
      }
    } catch (_) {
      existing.clear();
    }

    for (final id in uniqueIds) {
      try {
        final track = await core.getTrack(trackId: id);
        if (!existing.add(track.uid)) {
          already++;
        } else {
          await core.addToPlaylist(
            playlistId: playlist.id,
            trackUid: track.uid,
          );
          added++;
        }
      } catch (_) {
        failed++;
      }
      progress.value++;
    }
    if (context.mounted) {
      ref.invalidate(playlistsProvider);
      ref.invalidate(playlistEntriesProvider(playlist.id));
    }
    if (navigator.mounted && navigator.canPop()) navigator.pop();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              PlaylistStrings.addedTracksTo(
                added,
                already,
                failed,
                playlist.name,
              ),
            ),
          ),
        );
    }
    return added > 0 || already > 0;
  } catch (e) {
    if (navigator.mounted && navigator.canPop()) navigator.pop();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(PlaylistStrings.addFailed(describeCoreError(e))),
          ),
        );
    }
    return false;
  } finally {
    progress.dispose();
  }
}

class _PlaylistPickerFrame extends StatelessWidget {
  const _PlaylistPickerFrame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: LayoutBuilder(
      builder: (_, bounds) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: bounds.maxHeight * 0.78),
        child: child,
      ),
    ),
  );
}

class _AddTracksPlaylistPicker extends StatefulWidget {
  const _AddTracksPlaylistPicker({required this.count});

  final int count;

  @override
  State<_AddTracksPlaylistPicker> createState() =>
      _AddTracksPlaylistPickerState();
}

class _AddTracksPlaylistPickerState extends State<_AddTracksPlaylistPicker> {
  late final Future<List<PlaylistDto>> _future = core.listPlaylists();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return FutureBuilder<List<PlaylistDto>>(
      future: _future,
      builder: (context, snapshot) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LekisSpacing.xl,
                0,
                LekisSpacing.xl,
                LekisSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    PlaylistStrings.addToPlaylist,
                    style: theme.textTheme.titleLarge,
                  ),
                  Text(
                    PlaylistStrings.songCount(widget.count),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: switch (snapshot.connectionState) {
                ConnectionState.waiting => const Center(
                  heightFactor: 2,
                  child: CircularProgressIndicator(),
                ),
                _ when snapshot.hasError => Center(
                  heightFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(LekisSpacing.xl),
                    child: Text(
                      PlaylistStrings.loadFailed(
                        describeCoreError(snapshot.error!),
                      ),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                _ => _PlaylistPickerList(
                  playlists: snapshot.data ?? const <PlaylistDto>[],
                  busyPlaylist: null,
                  onAdd: (playlist) => Navigator.of(context).pop(playlist),
                ),
              },
            ),
          ],
        );
      },
    );
  }
}

class AddToPlaylistSheet extends ConsumerStatefulWidget {
  const AddToPlaylistSheet({super.key, required this.trackId, this.trackTitle});

  final int trackId;
  final String? trackTitle;

  @override
  ConsumerState<AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<AddToPlaylistSheet> {
  late Future<_PickerData> _future;
  String? _notice;
  int? _busyPlaylist;
  final _name = TextEditingController();
  bool _editingName = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _openNameField() {
    if (_busyPlaylist != null) return;
    _name.clear();
    setState(() {
      _editingName = true;
      _notice = null;
    });
  }

  void _cancelName() {
    FocusScope.of(context).unfocus();
    setState(() {
      _editingName = false;
      _notice = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_PickerData> _load() async {
    final results = await Future.wait<Object>([
      core.getTrack(trackId: widget.trackId),
      core.listPlaylists(),
    ]);
    return _PickerData(
      track: results[0] as TrackDto,
      playlists: results[1] as List<PlaylistDto>,
    );
  }

  Future<void> _add(_PickerData data, PlaylistDto playlist) async {
    if (_busyPlaylist != null) return;
    setState(() {
      _busyPlaylist = playlist.id;
      _notice = null;
    });
    try {
      final exists = await playlistContainsTrack(playlist.id, data.track.uid);
      if (exists) {
        if (mounted) {
          setState(() {
            _busyPlaylist = null;
            _notice = PlaylistStrings.alreadyIn(playlist.name);
          });
        }
        return;
      }
      await core.addToPlaylist(
        playlistId: playlist.id,
        trackUid: data.track.uid,
      );
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      Navigator.of(context).pop(_AddResult(playlist.name, created: false));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyPlaylist = null;
        _notice = PlaylistStrings.addFailed(describeCoreError(e));
      });
    }
  }

  Future<void> _createAndAdd(_PickerData data) async {
    if (_busyPlaylist != null) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _notice = PlaylistStrings.nameEmpty);
      return;
    }
    setState(() {
      _busyPlaylist = -1;
      _notice = null;
    });
    int? id;
    try {
      id = await core.createPlaylist(name: name);
      await core.addToPlaylist(playlistId: id, trackUid: data.track.uid);
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      Navigator.of(context).pop(_AddResult(name, created: true));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyPlaylist = null;
        if (id != null) {
          _editingName = false;
          _future = _load();
        }
        _notice = PlaylistStrings.createFailed(describeCoreError(e));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    return FutureBuilder<_PickerData>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final picker = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LekisSpacing.xl,
                0,
                LekisSpacing.xl,
                LekisSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          PlaylistStrings.addToPlaylist,
                          style: theme.textTheme.titleLarge,
                        ),
                        if (widget.trackTitle != null)
                          Text(
                            widget.trackTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: data == null || _busyPlaylist != null
                        ? null
                        : _openNameField,
                    icon: const Icon(Icons.add_rounded),
                    label: Text(PlaylistStrings.newShort),
                  ),
                ],
              ),
            ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LekisSpacing.xl,
                  0,
                  LekisSpacing.xl,
                  LekisSpacing.sm,
                ),
                child: Text(
                  _notice!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            const Divider(height: 1),
            Flexible(
              child: switch (snapshot.connectionState) {
                ConnectionState.waiting => const Center(
                  heightFactor: 2,
                  child: CircularProgressIndicator(),
                ),
                _ when snapshot.hasError => Center(
                  heightFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(LekisSpacing.xl),
                    child: Text(
                      PlaylistStrings.loadFailed(
                        describeCoreError(snapshot.error!),
                      ),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                _ => _PlaylistPickerList(
                  playlists: data!.playlists,
                  busyPlaylist: _busyPlaylist,
                  onAdd: (playlist) => _add(data, playlist),
                ),
              },
            ),
          ],
        );
        final editing = _editingName && data != null;
        return PopScope<_AddResult>(
          canPop: !editing,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && editing && _busyPlaylist == null) _cancelName();
          },
          child: AnimatedSwitcher(
            duration:
                MediaQuery.disableAnimationsOf(context) ||
                    MediaQuery.reduceMotionOf(context)
                ? Duration.zero
                : LekisMotion.fast,
            child: editing
                ? ListView(
                    key: const ValueKey('playlist-name'),
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(
                      LekisSpacing.xl,
                      0,
                      LekisSpacing.xl,
                      LekisSpacing.lg,
                    ),
                    children: [
                      Text(
                        PlaylistStrings.newPlaylist,
                        style: theme.textTheme.titleLarge,
                      ),
                      if (widget.trackTitle != null)
                        Text(
                          widget.trackTitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      const SizedBox(height: LekisSpacing.lg),
                      TextField(
                        controller: _name,
                        autofocus: true,
                        enabled: _busyPlaylist == null,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          labelText: PlaylistStrings.nameLabel,
                          errorText: _notice,
                        ),
                        onSubmitted: (_) => _createAndAdd(data),
                      ),
                      const SizedBox(height: LekisSpacing.md),
                      OverflowBar(
                        alignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: _busyPlaylist == null
                                ? _cancelName
                                : null,
                            child: Text(PlaylistStrings.cancel),
                          ),
                          FilledButton(
                            onPressed: _busyPlaylist == null
                                ? () => _createAndAdd(data)
                                : null,
                            child: Text(PlaylistStrings.createAndAdd),
                          ),
                        ],
                      ),
                    ],
                  )
                : picker,
          ),
        );
      },
    );
  }
}

class _PlaylistPickerList extends StatelessWidget {
  const _PlaylistPickerList({
    required this.playlists,
    required this.busyPlaylist,
    required this.onAdd,
  });

  final List<PlaylistDto> playlists;
  final int? busyPlaylist;
  final ValueChanged<PlaylistDto> onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    if (playlists.isEmpty) {
      return Center(
        heightFactor: 1,
        child: Padding(
          padding: const EdgeInsets.all(LekisSpacing.xl),
          child: Text(
            PlaylistStrings.noPlaylistsCreate,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      key: const PageStorageKey('add-playlist-options'),
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
      itemCount: playlists.length,
      itemBuilder: (context, i) {
        final playlist = playlists[i];
        final smart = playlist.kind == PlaylistKindDto.smart;
        final busy = busyPlaylist == playlist.id;
        return ListTile(
          enabled: !smart && busyPlaylist == null,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: LekisSpacing.xl,
          ),
          leading: Icon(
            smart ? Icons.auto_awesome_rounded : Icons.queue_music_rounded,
            color: smart ? colors.accent : colors.onSurfaceVariant,
          ),
          title: Text(playlist.name),
          subtitle: Text(
            smart
                ? PlaylistStrings.smartNotAddable
                : PlaylistStrings.songCount(playlist.trackCount),
          ),
          trailing: busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : smart
              ? const Icon(Icons.lock_outline_rounded, size: 18)
              : const Icon(Icons.add_circle_outline_rounded),
          onTap: smart || busyPlaylist != null ? null : () => onAdd(playlist),
        );
      },
    );
  }
}
