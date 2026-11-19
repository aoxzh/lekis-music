// 局域网发现的界面状态：一次性扫描、结果、失败原因。
//
// 扫描本身在核心（mDNS / WS-Discovery / SSDP）里跑；这里只负责：
// * Android 扫描期间持有组播锁；
// * 防止重复扫描（上一次没结束时不会再发一次）；
// * 页面关掉后不再回写状态（cancel-safe）。

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/lan_discovery_lock.dart';
import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';

/// 一次扫描最多等多久。核心会把超时限制在 0.5~30 秒。
const Duration lanDiscoveryTimeout = Duration(seconds: 6);

@immutable
class LanDiscoveryState {
  const LanDiscoveryState({
    this.scanning = false,
    this.hasScanned = false,
    this.results = const [],
    this.error,
  });

  /// 扫描进行中。
  final bool scanning;

  /// 已经完整跑过至少一次扫描（用来区分「还没扫」和「扫过但没结果」）。
  final bool hasScanned;

  final List<DiscoveredServiceDto> results;

  /// 扫描失败的原因（一般是桥接 / 平台错误）。
  final Object? error;

  bool get isEmpty =>
      hasScanned && !scanning && error == null && results.isEmpty;
}

final lanDiscoveryProvider =
    NotifierProvider.autoDispose<LanDiscoveryNotifier, LanDiscoveryState>(
      LanDiscoveryNotifier.new,
    );

class LanDiscoveryNotifier extends Notifier<LanDiscoveryState> {
  bool _disposed = false;

  /// 每次扫描的序号：关页 / 重扫时旧结果直接丢弃。
  int _run = 0;

  @override
  LanDiscoveryState build() {
    ref.onDispose(() => _disposed = true);
    return const LanDiscoveryState();
  }

  /// 扫一遍局域网。已有扫描在进行时直接返回。
  Future<void> scan() async {
    if (_disposed || state.scanning) return;
    final run = ++_run;
    state = const LanDiscoveryState(scanning: true);
    try {
      final found = await withLanMulticastLock(
        () => core.discoverLan(timeoutMs: lanDiscoveryTimeout.inMilliseconds),
      );
      if (_disposed || run != _run) return;
      state = LanDiscoveryState(
        hasScanned: true,
        results: List.unmodifiable(_prioritize(found)),
      );
    } catch (e) {
      if (_disposed || run != _run) return;
      state = LanDiscoveryState(hasScanned: true, error: e);
    }
  }

  /// SMB / WebDAV 能直接预填表单，排在仅作提示的 DLNA 前面。
  static List<DiscoveredServiceDto> _prioritize(
    List<DiscoveredServiceDto> found,
  ) {
    final sorted = [...found];
    sorted.sort((a, b) {
      final actionableA = a.kind != DiscoveredKindDto.mediaServer;
      final actionableB = b.kind != DiscoveredKindDto.mediaServer;
      if (actionableA != actionableB) return actionableA ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }
}
