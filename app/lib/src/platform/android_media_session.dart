// Android 系统媒体会话：通知栏 / 锁屏 / 蓝牙按键。
//
// 播放发生在 Rust 核心里，这里的 AudioHandler 只做两件事：
// 1. 把核心的播放状态（coreEvents / playbackSnapshot）镜像成 audio_service 的 MediaItem / PlaybackState；
// 2. 把系统发来的播放控制转发给核心。
// 音频焦点和「耳机拔出」用 audio_session 处理，同样只是调用核心的 pause / play。

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';

/// 启动 Android 媒体会话。只能调用一次（由 `initSystemMediaSession` 保证）。
Future<void> initAndroidMediaSession() async {
  // Android 13+ 发通知需要运行时权限；更低版本 permission_handler 直接返回 granted。
  try {
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  } catch (e) {
    debugPrint('media session: notification permission request failed: $e');
  }

  final handler = await AudioService.init<LekisAudioHandler>(
    builder: LekisAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'dev.lekis.lekis.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationChannelDescription: 'Lekis playback controls',
      androidNotificationIcon: 'mipmap/ic_launcher',
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
    ),
  );
  await handler.start();
}

/// 把核心播放状态镜像给系统，并把系统控制转发给核心。
class LekisAudioHandler extends BaseAudioHandler with SeekHandler {
  StreamSubscription<CoreEventDto>? _events;
  AudioSession? _session;

  PlaybackStateDto _state = PlaybackStateDto.idle;
  int? _trackId;
  int _durationMs = 0;
  int _positionMs = 0;
  DateTime _positionAt = DateTime.now();

  /// 上一次推给系统的状态是否是「播放中」（用来判断何时申请音频焦点）。
  bool _wasPlaying = false;

  /// 因为音频焦点被暂时拿走而暂停的（焦点回来时自动继续）。
  bool _pausedByInterruption = false;

  /// 闪避前的音量（`null` = 当前没有闪避）。
  double? _volumeBeforeDuck;

  /// 元数据请求的序号：切歌很快时丢弃过期的结果。
  int _metadataSeq = 0;

  Future<void> start() async {
    await _initAudioSession();

    final snap = core.playbackSnapshot();
    _applyPlayback(
      state: snap.state,
      trackId: snap.trackId,
      positionMs: snap.positionMs.toInt(),
      durationMs: snap.durationMs.toInt(),
    );

    _events = core.coreEvents().listen(
      (event) {
        switch (event) {
          case CoreEventDto_PlaybackChanged(
            :final state,
            :final trackId,
            :final positionMs,
            :final durationMs,
          ):
            _applyPlayback(
              state: state,
              trackId: trackId,
              positionMs: positionMs.toInt(),
              durationMs: durationMs.toInt(),
            );
          case CoreEventDto_PositionTick(:final positionMs):
            _applyTick(positionMs.toInt());
          default:
            break;
        }
      },
      onError: (Object e) => debugPrint('media session: core events error: $e'),
    );
  }

  Future<void> dispose() async {
    await _events?.cancel();
    _events = null;
  }

  // ---- 音频焦点 / 耳机拔出 ----

  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _session = session;

      session.becomingNoisyEventStream.listen((_) {
        _pausedByInterruption = false;
        _safe(core.pause);
      });

      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              if (_isPlaying(_state) && _volumeBeforeDuck == null) {
                final volume = core.playbackSnapshot().volume;
                _volumeBeforeDuck = volume;
                _safe(() => core.setVolume(volume: volume * 0.3));
              }
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (_isPlaying(_state)) {
                _pausedByInterruption = event.type == AudioInterruptionType.pause;
                _safe(core.pause);
              }
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              final restore = _volumeBeforeDuck;
              _volumeBeforeDuck = null;
              if (restore != null) {
                _safe(() => core.setVolume(volume: restore));
              }
            case AudioInterruptionType.pause:
              if (_pausedByInterruption) {
                _pausedByInterruption = false;
                _safe(core.play);
              }
            case AudioInterruptionType.unknown:
              _pausedByInterruption = false;
          }
        }
      });
    } catch (e) {
      debugPrint('media session: audio_session init failed: $e');
    }
  }

  /// 开始播放时申请音频焦点；拿不到就暂停。
  Future<void> _requestFocus() async {
    final session = _session;
    if (session == null) return;
    try {
      final granted = await session.setActive(true);
      if (!granted) _safe(core.pause);
    } catch (e) {
      debugPrint('media session: setActive failed: $e');
    }
  }

  // ---- 核心状态 → 系统 ----

  void _applyPlayback({
    required PlaybackStateDto state,
    required int? trackId,
    required int positionMs,
    required int durationMs,
  }) {
    final trackChanged = trackId != _trackId;
    final durationChanged = durationMs != _durationMs && durationMs > 0;
    _state = state;
    _trackId = trackId;
    _durationMs = durationMs;
    _positionMs = positionMs;
    _positionAt = DateTime.now();

    if (trackChanged || durationChanged) {
      unawaited(_updateMediaItem(trackId, durationMs));
    }

    final playing = _isPlaying(state);
    if (playing && !_wasPlaying) {
      _pausedByInterruption = false;
      unawaited(_requestFocus());
    }
    _wasPlaying = playing;

    _pushPlaybackState();
  }

  /// audio_service 会按 updateTime + speed 自己外推进度，所以平时不用推；
  /// 只有实际位置和外推位置偏差较大（缓冲卡顿等）时才校正一次。
  void _applyTick(int positionMs) {
    if (!_isPlaying(_state)) return;
    final expected =
        _positionMs + DateTime.now().difference(_positionAt).inMilliseconds;
    if ((positionMs - expected).abs() < 1500) return;
    _positionMs = positionMs;
    _positionAt = DateTime.now();
    _pushPlaybackState();
  }

  void _pushPlaybackState() {
    final playing = _isPlaying(_state);
    final processing = switch (_state) {
      PlaybackStateDto.idle =>
        _trackId == null ? AudioProcessingState.idle : AudioProcessingState.ready,
      PlaybackStateDto.loading => AudioProcessingState.loading,
      PlaybackStateDto.buffering => AudioProcessingState.buffering,
      PlaybackStateDto.playing || PlaybackStateDto.paused =>
        AudioProcessingState.ready,
      PlaybackStateDto.ended => AudioProcessingState.completed,
    };
    // copyWith 不能改 updateTime，所以整个重建。
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: processing,
        playing: playing,
        updatePosition: Duration(milliseconds: _positionMs),
        updateTime: _positionAt,
        speed: 1.0,
      ),
    );
  }

  Future<void> _updateMediaItem(int? trackId, int durationMs) async {
    final seq = ++_metadataSeq;
    if (trackId == null) {
      mediaItem.add(null);
      return;
    }
    try {
      final track = await core.getTrack(trackId: trackId);
      Uri? artUri;
      try {
        final art = await core.artwork(trackId: trackId);
        if (art != null) {
          final path = core.artworkPath(hash: art.hash, width: 512);
          if (await File(path).exists()) artUri = Uri.file(path);
        }
      } catch (e) {
        debugPrint('media session: artwork lookup failed: $e');
      }
      if (seq != _metadataSeq) return;

      final overlay = track.overlay;
      final artists = overlay?.artists ?? track.artists;
      final ms = durationMs > 0 ? durationMs : track.durationMs.toInt();
      mediaItem.add(
        MediaItem(
          id: trackId.toString(),
          title: overlay?.title ?? track.title,
          artist: artists.isEmpty ? null : artists.join(', '),
          album: overlay?.albumTitle ?? track.albumTitle,
          duration: ms > 0 ? Duration(milliseconds: ms) : null,
          artUri: artUri,
        ),
      );
    } catch (e) {
      debugPrint('media session: getTrack($trackId) failed: $e');
    }
  }

  // ---- 系统 → 核心 ----

  @override
  Future<void> play() async => _safe(core.play);

  @override
  Future<void> pause() async => _safe(core.pause);

  @override
  Future<void> stop() async {
    _safe(core.pause);
    await _session?.setActive(false);
    await super.stop();
  }

  @override
  Future<void> skipToNext() async => _safe(core.next);

  @override
  Future<void> skipToPrevious() async => _safe(core.previous);

  @override
  Future<void> seek(Duration position) async {
    final ms = position.inMilliseconds < 0 ? 0 : position.inMilliseconds;
    _safe(() => core.seek(positionMs: BigInt.from(ms)));
  }

  @override
  Future<void> onTaskRemoved() async {
    // 划掉最近任务时停止播放（核心进程也会随之结束）。
    await stop();
  }

  static bool _isPlaying(PlaybackStateDto s) =>
      s == PlaybackStateDto.playing ||
      s == PlaybackStateDto.buffering ||
      s == PlaybackStateDto.loading;

  static void _safe(void Function() f) {
    try {
      f();
    } catch (e) {
      debugPrint('media session: core call failed: $e');
    }
  }
}
