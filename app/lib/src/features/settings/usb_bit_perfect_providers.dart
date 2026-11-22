// Android USB DAC 比特完美直出（PLY-05）：开关与实时状态。
//
// 核心里的 `usb_output` 负责一切：开关持久化、按曲目协商格式、插拔后重建输出流。
// 这里只把状态搬到界面上：进入设置时重新探测一次设备，之后定时读状态快照
// （热插拔由 Kotlin 的 AudioDeviceCallback 通知核心，读快照就能看到）。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/dto.dart';
import '../../rust/api/usb_output.dart';
import 'settings_providers.dart';

/// 核心 USB 直出接口（测试里替换成假的）。
abstract interface class UsbBitPerfectApi {
  /// 当前状态快照（只读缓存，很便宜）。
  UsbBitPerfectStatusDto status();

  /// 重新探测 USB 设备再返回状态。
  UsbBitPerfectStatusDto refresh();

  /// 打开 / 关闭并持久化；返回引擎随之使用的输出模式（非 Android 为 `null`）。
  Future<OutputModeDto?> setEnabled(bool enabled);
}

class RustUsbBitPerfectApi implements UsbBitPerfectApi {
  const RustUsbBitPerfectApi();

  @override
  UsbBitPerfectStatusDto status() => usbBitPerfectStatus();

  @override
  UsbBitPerfectStatusDto refresh() => refreshUsbBitPerfect();

  @override
  Future<OutputModeDto?> setEnabled(bool enabled) =>
      setUsbBitPerfect(enabled: enabled);
}

final usbBitPerfectApiProvider = Provider<UsbBitPerfectApi>(
  (ref) => const RustUsbBitPerfectApi(),
);

/// 这个平台有没有 USB DAC 直出（只有 Android）。测试可以覆盖。
final usbBitPerfectSupportedProvider = Provider<bool>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
);

/// 核心不可用时的占位状态。
const _unavailable = UsbBitPerfectStatusDto(
  available: false,
  enabled: false,
  state: UsbBitPerfectStateDto.unavailable,
  deviceSupportsBitPerfect: false,
  sdkInt: 0,
  sourceFloat: false,
);

/// USB 直出的实时状态。只在有人看（设置页打开）时存在并轮询。
final usbBitPerfectProvider =
    NotifierProvider.autoDispose<UsbBitPerfectNotifier, UsbBitPerfectStatusDto>(
      UsbBitPerfectNotifier.new,
    );

class UsbBitPerfectNotifier extends Notifier<UsbBitPerfectStatusDto> {
  /// 轮询间隔：插拔、换曲后的格式回退都在这个延迟内出现在界面上。
  static Duration pollInterval = const Duration(seconds: 2);

  late UsbBitPerfectApi _api;

  @override
  UsbBitPerfectStatusDto build() {
    _api = ref.watch(usbBitPerfectApiProvider);
    final timer = Timer.periodic(pollInterval, (_) => _poll());
    ref.onDispose(timer.cancel);
    return _read(_api.refresh);
  }

  UsbBitPerfectStatusDto _read(UsbBitPerfectStatusDto Function() f) {
    try {
      return f();
    } catch (_) {
      return _unavailable;
    }
  }

  void _poll() {
    final next = _read(_api.status);
    if (next != state) state = next;
  }

  /// 重新探测设备（手动刷新）。
  void refresh() => state = _read(_api.refresh);

  /// 打开 / 关闭。失败时抛出核心错误（由 settingsGuard 提示）。
  Future<void> setEnabled(bool enabled) async {
    final mode = await _api.setEnabled(enabled);
    // 引擎的输出模式跟着开关变了（Android：开 = 独占，关 = 共享），让输出模式界面同步。
    if (mode != null) {
      ref.read(playbackOutputProvider.notifier).adoptMode(mode);
    }
    if (!ref.mounted) return;
    state = _read(_api.refresh);
  }
}
