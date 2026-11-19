import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/app.dart';
import 'package:lekis/src/bridge/core_init.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/settings/theme_preference.dart';
import 'package:lekis/src/platform/media_session.dart';
import 'package:lekis/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw behind system bars on Android; no orientation lock anywhere.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  try {
    await RustLib.init();
    await initLekisCore();
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'lekis',
        context: ErrorDescription('while starting the Lekis core'),
      ),
    );
    runApp(LekisStartupErrorApp(error: error));
    return;
  }

  // 主题要在首帧前恢复，避免先闪一下默认主题；其余服务不阻塞首帧。
  final container = ProviderContainer();
  await restoreThemePreference(container);

  runApp(
    UncontrolledProviderScope(container: container, child: const LekisApp()),
  );

  // 播放输出和锁屏 / 通知栏 / 系统媒体控制可以晚于首帧初始化。
  // 失败只记日志，不影响界面；这样冷启动只等核心和主题。
  unawaited(_startBackgroundServices());
}

Future<void> _startBackgroundServices() async {
  try {
    await Future.wait([restorePlaybackOutput(), initSystemMediaSession()]);
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'lekis',
        context: ErrorDescription('while starting background playback services'),
      ),
    );
  }
}
