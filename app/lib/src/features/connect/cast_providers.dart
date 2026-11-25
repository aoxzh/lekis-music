// Chromecast 与 DLNA/UPnP 音箱投放状态管理。
//
// 扫描在 Android 上通过 [withLanMulticastLock] 持有 WifiManager.MulticastLock，
// 确保 mDNS（_googlecast._tcp）与 SSDP（AVTransport:1）组播包能正常接收。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/lan_discovery_lock.dart';
import '../../rust/api/cast.dart' as cast_api;
import '../player/player_providers.dart';

@immutable
class CastUiState {
  const CastUiState({
    this.devices = const [],
    this.discovering = false,
    this.active,
    this.busy = false,
    this.error,
  });

  final List<cast_api.CastDeviceDto> devices;
  final bool discovering;
  final cast_api.CastPlaybackStateDto? active;
  final bool busy;
  final Object? error;

  bool get isCasting => active != null;

  CastUiState copyWith({
    List<cast_api.CastDeviceDto>? devices,
    bool? discovering,
    cast_api.CastPlaybackStateDto? active,
    bool clearActive = false,
    bool? busy,
    Object? error,
    bool clearError = false,
  }) => CastUiState(
    devices: devices ?? this.devices,
    discovering: discovering ?? this.discovering,
    active: clearActive ? null : (active ?? this.active),
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
  );
}

final castProvider = NotifierProvider<CastNotifier, CastUiState>(
  CastNotifier.new,
);

class CastNotifier extends Notifier<CastUiState> {
  @override
  CastUiState build() => const CastUiState();

  /// 扫描局域网内的 Chromecast 与 DLNA 渲染设备。
  Future<void> discover({int timeoutMs = 3000}) async {
    if (state.discovering) return;
    state = state.copyWith(discovering: true, clearError: true);
    try {
      final results = await withLanMulticastLock(
        () => cast_api.castDiscover(timeoutMs: timeoutMs),
      );
      final currentStatus = await cast_api.castStatus().catchError((_) => null);
      state = state.copyWith(
        devices: results,
        discovering: false,
        active: currentStatus,
        clearActive: currentStatus == null,
      );
    } catch (e) {
      state = state.copyWith(discovering: false, error: e);
    }
  }

  /// 将当前或指定曲目投放到目标 Chromecast / DLNA 设备。
  Future<void> castTrack(
    cast_api.CastDeviceDto device, {
    required int trackId,
    int positionMs = 0,
  }) async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      if (ref.read(playbackProvider).isPlaying) {
        ref.read(playerActionsProvider).pause();
      }
      final status = await cast_api.castPlayTrack(
        device: device,
        trackId: trackId,
        positionMs: BigInt.from(positionMs.clamp(0, 1 << 50)),
      );
      state = state.copyWith(busy: false, active: status);
    } catch (e) {
      state = state.copyWith(busy: false, error: e);
      rethrow;
    }
  }

  /// 切换暂停 / 继续。
  Future<void> togglePlayPause() async {
    final active = state.active;
    if (active == null || state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      if (active.isPlaying) {
        await cast_api.castPause();
      } else {
        await cast_api.castResume();
      }
      final updated = await cast_api.castStatus();
      state = state.copyWith(
        busy: false,
        active: updated,
        clearActive: updated == null,
      );
    } catch (e) {
      state = state.copyWith(busy: false, error: e);
      rethrow;
    }
  }

  /// 调节投放设备音量（0.0..1.0）。
  Future<void> setVolume(double volume) async {
    final active = state.active;
    if (active == null) return;
    final clamped = volume.clamp(0.0, 1.0);
    try {
      await cast_api.castSetVolume(volume: clamped);
      final updated = await cast_api.castStatus();
      if (updated != null) {
        state = state.copyWith(active: updated);
      }
    } catch (e) {
      state = state.copyWith(error: e);
    }
  }

  /// 跳转进度（毫秒）。
  Future<void> seek(int positionMs) async {
    if (state.active == null) return;
    try {
      await cast_api.castSeek(
        positionMs: BigInt.from(positionMs.clamp(0, 1 << 50)),
      );
      final updated = await cast_api.castStatus();
      if (updated != null) {
        state = state.copyWith(active: updated);
      }
    } catch (e) {
      state = state.copyWith(error: e);
    }
  }

  /// 停止当前投放。
  Future<void> stop() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await cast_api.castStop();
      state = state.copyWith(busy: false, clearActive: true);
    } catch (e) {
      state = state.copyWith(busy: false, clearActive: true, error: e);
    }
  }
}
