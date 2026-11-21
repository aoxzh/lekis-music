// 网络环境（SRC-14）：在家（Wi-Fi / 有线）还是在外（只有移动网络）。
//
// 核心据此调整选源顺序：在外时局域网地址降权、优先公网地址，媒体服务器
// 转码到 320 kbps 省流量。判断很朴素：有 Wi-Fi 或有线就算在家；只有
// 移动网络才算在外；完全断网时保持上一次的判断（断网时选什么源都一样）。

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/rust/api/core.dart' as core;

/// 根据当前连接判断是否在外；断网（或拿不到信息）时返回 `null`，表示不改。
@visibleForTesting
bool? awayFromConnectivity(List<ConnectivityResult> results) {
  final home = results.any(
    (r) => r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet,
  );
  if (home) return false;
  if (results.contains(ConnectivityResult.mobile)) return true;
  return null;
}

/// 常驻服务：监听连接变化并告诉核心。在 `LekisApp` 里 watch。
final networkContextProvider = Provider<void>((ref) {
  final connectivity = Connectivity();
  bool? last;

  void apply(List<ConnectivityResult> results) {
    final away = awayFromConnectivity(results);
    if (away == null || away == last) return;
    last = away;
    debugPrint('network context: ${away ? 'away' : 'home'} ($results)');
    core.setNetworkAway(away: away);
  }

  StreamSubscription<List<ConnectivityResult>>? sub;
  try {
    sub = connectivity.onConnectivityChanged.listen(
      apply,
      onError: (Object e) => debugPrint('connectivity: $e'),
    );
    unawaited(
      connectivity.checkConnectivity().then(apply).catchError((Object e) {
        debugPrint('connectivity: $e');
      }),
    );
  } catch (e) {
    // 平台不支持时（测试环境、少见的桌面配置）就保持核心默认的"在家"。
    debugPrint('connectivity unavailable: $e');
  }
  ref.onDispose(() => sub?.cancel());
});
