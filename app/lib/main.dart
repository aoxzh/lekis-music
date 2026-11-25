import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/app.dart';
import 'package:lekis/src/bridge/core_init.dart';
import 'package:lekis/src/features/now_playing/now_playing_style.dart';
import 'package:lekis/src/features/player/playback_session.dart';
import 'package:lekis/src/features/plugins/official_plugins.dart';
import 'package:lekis/src/features/settings/app_updater_provider.dart';
import 'package:lekis/src/features/settings/desktop_tray_settings.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/settings/theme_preference.dart';
import 'package:lekis/src/l10n/app_locale.dart';
import 'package:lekis/src/platform/desktop_tray/desktop_tray_controller.dart';
import 'package:lekis/src/platform/android_home_widget.dart';
import 'package:lekis/src/platform/media_session.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:lekis/src/shell/nav_bar_position.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Desktop album walls can keep more decoded thumbnails in memory; the
  // default ~100 MB budget starts evicting covers while scrolling a large
  // library. Phones keep the platform default to stay memory-friendly.
  if (defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux) {
    PaintingBinding.instance.imageCache.maximumSizeBytes = 192 * 1024 * 1024;
  }
  // Draw behind system bars on Android; no orientation lock anywhere.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  try {
    await RustLib.init();
    await initLekisCore();
    await ensureOfficialPlugins();
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

  // 主题、TabBar 样式和桌面托盘开关要在首帧前恢复，避免闪一下默认值；
  // 播放输出和媒体会话不阻塞首帧，runApp 之后再初始化。
  final container = ProviderContainer();
  await Future.wait([
    restoreThemePreference(container),
    restoreAppLocale(container),
    restoreNowPlayingStyle(container),
    restoreTabBarStyle(container),
    restoreNavBarPosition(container),
    restoreDesktopTraySettings(container),
  ]);

  // 先把窗口关闭钩子挂上（同步），保证第一下关闭按钮就遵守“最小化到托盘”；
  // 真正的托盘图标在首帧后创建，失败只记日志。
  final desktopTray = container.read(desktopTrayControllerProvider);
  desktopTray.installCloseHandler();

  runApp(
    UncontrolledProviderScope(container: container, child: const LekisApp()),
  );

  // 播放输出和锁屏 / 通知栏 / 系统媒体控制可以晚于首帧初始化。
  // 失败只记日志，不影响界面；这样冷启动只等核心和主题。
  unawaited(_startBackgroundServices(container, desktopTray));
}

Future<void> _startBackgroundServices(
  ProviderContainer container,
  DesktopTrayController desktopTray,
) async {
  try {
    await Future.wait([
      restorePlaybackOutput(),
      initSystemMediaSession(),
      desktopTray.initialize(),
    ]);
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'lekis',
        context: ErrorDescription(
          'while starting background playback services',
        ),
      ),
    );
  }

  // 首帧之后再恢复上次的播放会话（输出设备/模式已就绪）。恢复是暂停状态，
  // 不会自动出声；没有保存过会话时什么也不做。
  await container.read(playbackSessionProvider).restore();

  // 从桌面小组件打开时（「播放」或点按主体），会话恢复后再处理。
  await startHomeWidgetLaunchHandling();

  // 桌面端启动后静默检查一次新版本，不阻塞首帧。
  scheduleStartupUpdateCheck(container);
}
