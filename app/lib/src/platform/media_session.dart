// 系统媒体控件的统一入口：Android 用 audio_service，桌面端用 Rust 里的 souvlaki。

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:lekis/src/rust/api/media_controls.dart';

import 'android_media_session.dart';

bool _started = false;

/// 启用系统媒体控件（通知栏 / 锁屏 / 系统媒体浮窗 / 媒体键）。
///
/// 在 `initCore` 之后调用一次；重复调用直接返回。失败只打日志，不影响应用启动。
/// iOS 目前不处理。
Future<void> initSystemMediaSession() async {
  if (_started || kIsWeb) return;
  _started = true;
  try {
    if (Platform.isAndroid) {
      await initAndroidMediaSession();
    } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      if (!enableSystemMediaControls()) {
        debugPrint('media session: desktop media controls not enabled');
      }
    }
  } catch (e, st) {
    debugPrint('media session: init failed: $e\n$st');
  }
}
