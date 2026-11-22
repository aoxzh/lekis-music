// Root widget: themes, scroll behaviour and the navigation shell.

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'dev/perf_probe.dart';
import 'features/player/playback_session.dart';
import 'features/player/widgets/player_controls.dart';
import 'l10n/app_l10n.dart';
import 'l10n/app_locale.dart';
import 'platform/network_context.dart';
import 'platform/window_caption.dart';
import 'shell/app_shell.dart';
import 'theme/theme.dart';
import 'theme/theme_settings.dart';

class LekisApp extends ConsumerWidget {
  const LekisApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 常驻服务：播放会话保存 / 恢复，以及播放历史计数。
    ref.watch(playbackSessionProvider);
    ref.watch(playHistoryProvider);
    ref.watch(networkContextProvider);
    final themeMode = ref.watch(themeModeProvider);
    final oled = ref.watch(oledBlackProvider);
    final appLocale = ref.watch(appLocaleProvider);

    return MaterialApp(
      title: '月兔音乐',
      onGenerateTitle: (context) => context.l10n.appName,
      debugShowCheckedModeBanner: false,
      locale: appLocale.locale,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: lekisLightTheme(),
      darkTheme: lekisDarkTheme(oled: oled),
      themeMode: themeMode,
      themeAnimationDuration: LekisMotion.normal,
      scrollBehavior: const _LekisScrollBehavior(),
      // 窗口标题栏跟随应用的深浅色，而不是 Windows 的；同步注入 LekisLocale 驱动双语切换。
      builder: (context, child) => LekisLocale(
        locale: Localizations.localeOf(context),
        child: WindowCaptionSync(child: child ?? const SizedBox.shrink()),
      ),
      // 空格播放/暂停、媒体键等快捷键在整个应用里生效。
      home: const PerfProbe(child: PlayerShortcuts(child: AppShell())),
    );
  }
}

/// Lets mouse and trackpad drag horizontal carousels on desktop.
class _LekisScrollBehavior extends MaterialScrollBehavior {
  const _LekisScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.mouse,
    PointerDeviceKind.unknown,
  };
}

/// Shown instead of [LekisApp] when the core fails to start.
class LekisStartupErrorApp extends StatelessWidget {
  const LekisStartupErrorApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '月兔音乐',
      onGenerateTitle: (context) => context.l10n.appName,
      debugShowCheckedModeBanner: false,
      theme: lekisLightTheme(),
      darkTheme: lekisDarkTheme(),
      home: Builder(
        builder: (context) {
          final text = Theme.of(context).textTheme;
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(LekisSpacing.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.nightlight_round,
                        size: LekisSizes.touchTargetMin,
                        color: context.lekisColors.moon,
                      ),
                      const SizedBox(height: LekisSpacing.lg),
                      Text('Lekis 启动失败', style: text.titleLarge),
                      const SizedBox(height: LekisSpacing.sm),
                      SelectableText(
                        '$error',
                        textAlign: TextAlign.center,
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
