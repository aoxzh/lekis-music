// Root widget: themes, scroll behaviour and the navigation shell.

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'dev/perf_probe.dart';
import 'features/mini_mode/mini_player_window.dart';
import 'features/player/playback_session.dart';
import 'features/player/player_providers.dart';
import 'features/player/widgets/player_controls.dart';
import 'l10n/app_l10n.dart';
import 'l10n/app_locale.dart';
import 'platform/network_context.dart';
import 'platform/ui_profile.dart';
import 'platform/window_caption.dart';
import 'shell/app_shell.dart';
import 'theme/theme.dart';
import 'theme/theme_settings.dart';

class LekisApp extends ConsumerWidget {
  const LekisApp({super.key});

  /// Playback command failures are reported by [playerActionsProvider]; the
  /// root owns the messenger so a failure is visible on every page.
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 常驻服务：播放会话保存 / 恢复，以及播放历史计数。
    ref.watch(playbackSessionProvider);
    ref.watch(playHistoryProvider);
    ref.watch(networkContextProvider);
    ref.watch(artworkPrefetchProvider);
    final themeMode = ref.watch(themeModeProvider);
    final oled = ref.watch(oledBlackProvider);
    final appLocale = ref.watch(appLocaleProvider);

    ref.listen<PlaybackFailure?>(playbackErrorProvider, (previous, next) {
      if (next == null || next.message.isEmpty) return;
      final failure = next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        messengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(failure.message),
              action: failure.retry == null
                  ? null
                  : SnackBarAction(
                      label: L10n.tr('重试', 'Retry'),
                      onPressed: failure.retry!,
                    ),
            ),
          );
        ref.read(playbackErrorProvider.notifier).clear();
      });
    });

    return MaterialApp(
      title: L10n.tr('月兔音乐', 'Lekis Music'),
      scaffoldMessengerKey: messengerKey,
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
      // 窗口标题栏与移动端系统状态栏图标跟随应用的深浅色（含未挂载 AppBar 的页面）；
      // 同步注入 LekisLocale 驱动双语切换。
      builder: (context, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final overlay =
            (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
                .copyWith(
                  statusBarColor: Colors.transparent,
                  systemNavigationBarColor: Colors.transparent,
                  systemNavigationBarIconBrightness: isDark
                      ? Brightness.light
                      : Brightness.dark,
                );
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlay,
          child: LekisLocale(
            locale: Localizations.localeOf(context),
            child: WindowCaptionSync(
              // Desktop only: the window can shrink into the mini player.
              child: UiProfile.current.isDesktop
                  ? MiniModeHost(child: child ?? const SizedBox.shrink())
                  : child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
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
      title: L10n.tr('月兔音乐', 'Lekis Music'),
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
                      Text(
                        L10n.tr('Lekis 启动失败', 'Failed to start Lekis'),
                        style: text.titleLarge,
                      ),
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
