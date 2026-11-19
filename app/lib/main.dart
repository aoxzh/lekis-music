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

  // 把保存的设置交还给核心和界面（失败不影响启动）。
  final container = ProviderContainer();
  await Future.wait([
    restoreThemePreference(container),
    restorePlaybackOutput(),
  ]);
  // 锁屏 / 通知栏 / 系统媒体控制 / 媒体键。
  await initSystemMediaSession();

  runApp(
    UncontrolledProviderScope(container: container, child: const LekisApp()),
  );
}
