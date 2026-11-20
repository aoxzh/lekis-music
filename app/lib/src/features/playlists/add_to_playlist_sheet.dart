// "添加到歌单"选择器：从曲目行 / 正在播放 / 队列打开。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

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
    heightFactor: 0.72,
    builder: (_) =>
        AddToPlaylistSheet(trackId: trackId, trackTitle: trackTitle),
  );
  if (result == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          result.created
              ? '已新建“${result.playlistName}”并添加'
              : '已添加到“${result.playlistName}”',
        ),
      ),
    );
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
            _notice = '“${playlist.name}”里已经有这首歌了';
          });
        }
        return;
      }
      await core.addToPlaylist(
        playlistId: playlist.id,
        trackUid: data.track.uid,
      );
      if (!mounted) return;
      Navigator.of(context).pop(_AddResult(playlist.name, created: false));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyPlaylist = null;
        _notice = '添加失败：${describeCoreError(e)}';
      });
    }
  }

  Future<void> _createAndAdd(_PickerData data) async {
    final name = await askPlaylistName(
      context,
      title: '新建歌单',
      confirm: '创建并添加',
    );
    if (name == null) return;
    if (!mounted) return;
    setState(() {
      _busyPlaylist = -1;
      _notice = null;
    });
    try {
      final id = await core.createPlaylist(name: name);
      await core.addToPlaylist(playlistId: id, trackUid: data.track.uid);
      if (!mounted) return;
      Navigator.of(context).pop(_AddResult(name, created: true));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyPlaylist = null;
        _notice = '创建失败：${describeCoreError(e)}';
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
        return Column(
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
                        Text('添加到歌单', style: theme.textTheme.titleLarge),
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
                    onPressed: data == null ? null : () => _createAndAdd(data),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('新建'),
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
            Expanded(
              child: switch (snapshot.connectionState) {
                ConnectionState.waiting => const Center(
                  child: CircularProgressIndicator(),
                ),
                _ when snapshot.hasError => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(LekisSpacing.xl),
                    child: Text(
                      '加载失败：${describeCoreError(snapshot.error!)}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                _ => _PlaylistPickerList(
                  data: data!,
                  busyPlaylist: _busyPlaylist,
                  onAdd: (playlist) => _add(data, playlist),
                ),
              },
            ),
          ],
        );
      },
    );
  }
}

class _PlaylistPickerList extends StatelessWidget {
  const _PlaylistPickerList({
    required this.data,
    required this.busyPlaylist,
    required this.onAdd,
  });

  final _PickerData data;
  final int? busyPlaylist;
  final ValueChanged<PlaylistDto> onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    if (data.playlists.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(LekisSpacing.xl),
          child: Text(
            '还没有歌单，先新建一个吧',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
      itemCount: data.playlists.length,
      itemBuilder: (context, i) {
        final playlist = data.playlists[i];
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
            smart ? '智能歌单由规则管理，不能手动添加' : '${playlist.trackCount} 首歌曲',
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
