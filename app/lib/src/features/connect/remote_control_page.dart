// 遥控页：控制另一台设备正在播放的东西。
//
// 状态来自对方的推送（大约每秒一次，切歌时立刻推），两次推送之间进度在本地
// 按真实流逝时间外推，所以进度条是连续走的，而不是一秒一跳。拖动进度条和
// 音量时先只改本地显示，松手（音量是拖动中节流）才发给对方。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/dto.dart';
import '../../theme/theme.dart';
import 'connect_active.dart';
import 'connect_gateway.dart';
import 'connect_providers.dart';
import 'connect_strings.dart';
import 'connect_ui.dart';

/// 打开 [deviceId] 的遥控页（盖在整个外壳上面）。
Future<void> openRemoteControl(BuildContext context, String deviceId) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/connect/remote'),
        builder: (_) => RemoteControlPage(deviceId: deviceId),
      ),
    );

class RemoteControlPage extends ConsumerStatefulWidget {
  const RemoteControlPage({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<RemoteControlPage> createState() => _RemoteControlPageState();
}

class _RemoteControlPageState extends ConsumerState<RemoteControlPage> {
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  Future<void> _subscribe() async {
    try {
      await watchRemoteState(ref, widget.deviceId);
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  Future<void> _send(ControlActionDto action) async {
    try {
      await ref.read(connectGatewayProvider).control(widget.deviceId, action);
    } catch (error) {
      if (mounted) showConnectSnack(context, connectErrorText(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(
      connectProvider.select(
        (s) => s.value?.devices
            .where((d) => d.deviceId == widget.deviceId)
            .firstOrNull,
      ),
    );
    final state = ref.watch(remoteStateProvider(widget.deviceId));
    final name = device?.name ?? '';
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: context.lekisColors.onSurfaceVariant,
    );

    Widget body;
    if (device == null) {
      body = _Centered(text: ConnectStrings.remoteOffline, style: muted);
    } else if (state == null) {
      body = _loadError == null
          ? const Center(child: CircularProgressIndicator())
          : _Centered(text: connectErrorText(_loadError!), style: muted);
    } else if (state.track == null) {
      body = _Centered(text: ConnectStrings.nothingOnRemote, style: muted);
    } else {
      body = _RemoteBody(deviceId: widget.deviceId, state: state, send: _send);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          name.isEmpty
              ? ConnectStrings.title
              : ConnectStrings.playingOnDevice(name),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (ref.watch(activeRemoteProvider) == widget.deviceId)
            TextButton(
              key: const ValueKey('connect.remote.stop'),
              onPressed: () {
                ref.read(activeRemoteProvider.notifier).clear();
                Navigator.of(context).maybePop();
              },
              child: const Text(ConnectStrings.stopControlling),
            ),
          const SizedBox(width: LekisSpacing.sm),
        ],
      ),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(LekisSpacing.xl),
      child: Text(text, style: style, textAlign: TextAlign.center),
    ),
  );
}

class _RemoteBody extends StatelessWidget {
  const _RemoteBody({
    required this.deviceId,
    required this.state,
    required this.send,
  });

  final String deviceId;
  final RemoteStateDto state;
  final Future<void> Function(ControlActionDto) send;

  @override
  Widget build(BuildContext context) {
    final track = state.track!;
    final artwork = _RemoteArtwork(deviceId: deviceId, track: track);
    final controls = _RemoteControls(state: state, send: send);
    final queue = _RemoteQueue(deviceId: deviceId, state: state);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        if (wide) {
          return Padding(
            padding: const EdgeInsets.all(LekisSpacing.xl),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Flexible(child: Center(child: artwork)),
                      const SizedBox(height: LekisSpacing.xl),
                      controls,
                    ],
                  ),
                ),
                const SizedBox(width: LekisSpacing.xxl),
                Expanded(child: queue),
              ],
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(LekisSpacing.lg),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: artwork,
              ),
            ),
            const SizedBox(height: LekisSpacing.xl),
            controls,
            const SizedBox(height: LekisSpacing.xl),
            SizedBox(height: 320, child: queue),
          ],
        );
      },
    );
  }
}

class _RemoteArtwork extends ConsumerStatefulWidget {
  const _RemoteArtwork({required this.deviceId, required this.track});

  final String deviceId;
  final RemoteTrackDto track;

  @override
  ConsumerState<_RemoteArtwork> createState() => _RemoteArtworkState();
}

class _RemoteArtworkState extends ConsumerState<_RemoteArtwork> {
  late Future<Uint8List?> _bytes = _load();

  Future<Uint8List?> _load() => ref
      .read(connectGatewayProvider)
      .remoteArtwork(
        widget.deviceId,
        trackId: widget.track.id,
        uid: widget.track.uid,
      )
      .catchError((Object _) => null);

  @override
  void didUpdateWidget(covariant _RemoteArtwork old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id) _bytes = _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(LekisRadius.md),
        child: FutureBuilder<Uint8List?>(
          future: _bytes,
          builder: (context, snapshot) {
            final data = snapshot.data;
            return AnimatedSwitcher(
              duration: LekisMotion.normal,
              child: data == null
                  ? ColoredBox(
                      key: const ValueKey('placeholder'),
                      color: colors.surfaceVariant,
                      child: Icon(
                        Icons.music_note_rounded,
                        size: LekisSpacing.xxl * 2,
                        color: colors.onSurfaceVariant,
                      ),
                    )
                  : Image.memory(
                      data,
                      key: ValueKey(widget.track.id),
                      fit: BoxFit.cover,
                      // Remote covers can be full size: decode at a size that
                      // fits the page, not the original 3000 px.
                      cacheWidth: 1024,
                      gaplessPlayback: true,
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _RemoteControls extends StatefulWidget {
  const _RemoteControls({required this.state, required this.send});

  final RemoteStateDto state;
  final Future<void> Function(ControlActionDto) send;

  @override
  State<_RemoteControls> createState() => _RemoteControlsState();
}

class _RemoteControlsState extends State<_RemoteControls> {
  /// When the last pushed position arrived (for extrapolation).
  DateTime _stamp = DateTime.now();
  Timer? _tick;

  /// Local values while the user drags; null = follow the remote.
  double? _seekDrag;
  double? _volumeDrag;
  DateTime _lastVolumeSent = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _playing => widget.state.state == PlaybackStateDto.playing;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _RemoteControls old) {
    super.didUpdateWidget(old);
    if (old.state.positionMs != widget.state.positionMs ||
        old.state.state != widget.state.state ||
        old.state.track?.id != widget.state.track?.id) {
      _stamp = DateTime.now();
    }
    _syncTicker();
  }

  void _syncTicker() {
    if (_playing && _tick == null) {
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
    } else if (!_playing) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  int get _durationMs => widget.state.durationMs.toInt();

  int get _positionMs {
    final base = widget.state.positionMs.toInt();
    if (!_playing) return base;
    final elapsed = DateTime.now().difference(_stamp).inMilliseconds;
    final pos = base + elapsed;
    return _durationMs > 0 ? pos.clamp(0, _durationMs) : pos;
  }

  static String _fmt(int ms) {
    final s = (ms / 1000).floor();
    final m = s ~/ 60;
    return '$m:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _setVolume(double v, {bool force = false}) {
    setState(() => _volumeDrag = v);
    final now = DateTime.now();
    if (force || now.difference(_lastVolumeSent).inMilliseconds >= 120) {
      _lastVolumeSent = now;
      widget.send(ControlActionDto.volume(volume: v));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final state = widget.state;
    final track = state.track!;
    final duration = _durationMs;
    final position = _seekDrag?.round() ?? _positionMs;
    final subtitle = [
      track.artist,
      if (track.album case final album? when album.isNotEmpty) album,
    ].join(' · ');
    final via = track.via;

    return Column(
      key: const ValueKey('connect.remote.controls'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          track.title,
          key: const ValueKey('connect.remote.title'),
          style: theme.textTheme.headlineSmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: LekisSpacing.xxs),
        Text(
          subtitle,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colors.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (via != null) ...[
          const SizedBox(height: LekisSpacing.xxs),
          Text(
            ConnectStrings.viaLabel(via),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: LekisSpacing.md),
        Slider(
          key: const ValueKey('connect.remote.seek'),
          value: duration <= 0 ? 0 : position.clamp(0, duration).toDouble(),
          max: duration <= 0 ? 1 : duration.toDouble(),
          onChanged: duration <= 0
              ? null
              : (v) => setState(() => _seekDrag = v),
          onChangeEnd: duration <= 0
              ? null
              : (v) {
                  widget.send(
                    ControlActionDto.seek(positionMs: BigInt.from(v.round())),
                  );
                  // Keep showing the target until the next push lands.
                  _stamp = DateTime.now();
                  setState(() => _seekDrag = null);
                },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.lg),
          child: Row(
            children: [
              Text(_fmt(position), style: theme.textTheme.bodySmall),
              const Spacer(),
              Text(
                duration <= 0 ? '--:--' : '-${_fmt(duration - position)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: LekisSpacing.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: '随机播放',
              isSelected: state.shuffle != ShuffleModeDto.off,
              icon: const Icon(Icons.shuffle_rounded),
              selectedIcon: Icon(Icons.shuffle_rounded, color: colors.accent),
              onPressed: () => widget.send(
                ControlActionDto.shuffle(
                  mode: state.shuffle == ShuffleModeDto.off
                      ? ShuffleModeDto.random
                      : ShuffleModeDto.off,
                ),
              ),
            ),
            IconButton(
              tooltip: '上一首',
              iconSize: LekisSpacing.xxl,
              icon: const Icon(Icons.skip_previous_rounded),
              onPressed: () => widget.send(const ControlActionDto.previous()),
            ),
            IconButton.filled(
              key: const ValueKey('connect.remote.toggle'),
              tooltip: _playing ? '暂停' : '播放',
              iconSize: LekisSpacing.xxl + LekisSpacing.sm,
              icon: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              onPressed: () => widget.send(const ControlActionDto.toggle()),
            ),
            IconButton(
              tooltip: '下一首',
              iconSize: LekisSpacing.xxl,
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: () => widget.send(const ControlActionDto.next()),
            ),
            IconButton(
              tooltip: '循环',
              isSelected: state.repeat != RepeatModeDto.off,
              icon: Icon(
                state.repeat == RepeatModeDto.one
                    ? Icons.repeat_one_rounded
                    : Icons.repeat_rounded,
              ),
              selectedIcon: Icon(
                state.repeat == RepeatModeDto.one
                    ? Icons.repeat_one_rounded
                    : Icons.repeat_rounded,
                color: colors.accent,
              ),
              onPressed: () => widget.send(
                ControlActionDto.repeat(
                  mode: switch (state.repeat) {
                    RepeatModeDto.off => RepeatModeDto.all,
                    RepeatModeDto.all => RepeatModeDto.one,
                    RepeatModeDto.one => RepeatModeDto.off,
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: LekisSpacing.sm),
        Row(
          children: [
            const Icon(Icons.volume_down_rounded),
            Expanded(
              child: Slider(
                key: const ValueKey('connect.remote.volume'),
                semanticFormatterCallback: (v) =>
                    '${ConnectStrings.volume} ${(v * 100).round()}%',
                value: (_volumeDrag ?? state.volume).clamp(0.0, 1.0),
                onChanged: _setVolume,
                onChangeEnd: (v) {
                  _setVolume(v, force: true);
                  setState(() => _volumeDrag = null);
                },
              ),
            ),
            const Icon(Icons.volume_up_rounded),
          ],
        ),
      ],
    );
  }
}

class _RemoteQueue extends ConsumerStatefulWidget {
  const _RemoteQueue({required this.deviceId, required this.state});

  final String deviceId;
  final RemoteStateDto state;

  @override
  ConsumerState<_RemoteQueue> createState() => _RemoteQueueState();
}

class _RemoteQueueState extends ConsumerState<_RemoteQueue> {
  static const _pageSize = 30;

  late Future<List<RemoteTrackDto>> _page = _load();

  Future<List<RemoteTrackDto>> _load() => ref
      .read(connectGatewayProvider)
      .remoteQueue(
        widget.deviceId,
        offset: (widget.state.queueIndex ?? -1) + 1,
        limit: _pageSize,
      )
      .catchError((Object _) => const <RemoteTrackDto>[]);

  @override
  void didUpdateWidget(covariant _RemoteQueue old) {
    super.didUpdateWidget(old);
    if (old.state.queueVersion != widget.state.queueVersion ||
        old.state.queueIndex != widget.state.queueIndex) {
      _page = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: context.lekisColors.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(ConnectStrings.upNext, style: theme.textTheme.titleMedium),
        const SizedBox(height: LekisSpacing.sm),
        Expanded(
          child: FutureBuilder<List<RemoteTrackDto>>(
            future: _page,
            builder: (context, snapshot) {
              final items = snapshot.data ?? const <RemoteTrackDto>[];
              if (items.isEmpty) {
                return snapshot.connectionState == ConnectionState.done
                    ? Align(
                        alignment: Alignment.topLeft,
                        child: Text('—', style: muted),
                      )
                    : const SizedBox.shrink();
              }
              return ListView.builder(
                key: const ValueKey('connect.remote.queue'),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final t = items[i];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      t.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
