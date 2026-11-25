// Adaptive navigation shell.
//
//  * compact / medium width   → floating glass tab bar + MiniPlayer above it
//    (phones, unfolded foldables, small tablets)
//  * expanded width and up    → sidebar + desktop PlayerBar along the bottom
//  * compact height (any width, e.g. phone landscape) → NavigationRail
//
// Every size has the same destinations; each tab owns a nested Navigator
// kept alive in an IndexedStack, and the whole tab stack sits under one
// GlobalKey so resizing / folding only re-arranges the chrome around it.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/features/connect/connect_active.dart';
import 'package:lekis/src/features/connect/connect_runtime_host.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_controller.dart';
import 'package:lekis/src/features/now_playing/now_playing_route.dart';
import 'package:lekis/src/features/player/mini_player.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/player_bar.dart';
import 'package:lekis/src/features/settings/app_updater_provider.dart';
import 'package:lekis/src/features/sources/sources_page.dart';
import 'package:lekis/src/layout/window_size.dart';
import 'package:lekis/src/platform/android_home_widget.dart';
import 'package:lekis/src/theme/tokens.dart';

import 'destinations.dart';
import 'nav_bar_position.dart';
import 'now_playing_context.dart';
import 'routes.dart';
import 'shell_chrome.dart';
import 'sidebar.dart';
import 'tab_bar.dart';
import 'tab_bar_style.dart';

export 'destinations.dart' show LekisDestination;
export 'routes.dart'
    show
        openDownloads,
        openEnrichReview,
        openNowPlaying,
        openPlugins,
        NowPlayingRoute;

ShellChromeMode _chromeModeOf(BuildContext context, NavBarPosition navPos) {
  if (context.heightClass == WindowHeightClass.compact) {
    return ShellChromeMode.rail;
  }
  return switch (context.widthClass) {
    // 手机与折叠屏展开态 / 小平板（< 840 dp）默认采用底部悬浮玻璃栏（参考 Apple Music /
    // Spotify 折叠屏），用户也可在「外观 → 导航栏位置」切到左侧或右侧全宽穿透悬浮玻璃。
    WindowWidthClass.compact || WindowWidthClass.medium =>
      navPos == NavBarPosition.bottom
          ? ShellChromeMode.bottomBar
          : ShellChromeMode.sideTabs,
    _ => ShellChromeMode.sidebar,
  };
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  /// Switches the shell to [destination] from anywhere below it.
  static void select(BuildContext context, LekisDestination destination) =>
      context.findAncestorStateOfType<_AppShellState>()?._select(destination);

  static void openAddSource(BuildContext context) =>
      context.findAncestorStateOfType<_AppShellState>()?._openAddSource();

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const _destinations = LekisDestination.values;

  final _tabsKey = GlobalKey(debugLabel: 'AppShell.tabs');
  final _sourcesPageKey = GlobalKey<SourcesPageState>();
  final _navigatorKeys = [
    for (final d in _destinations)
      GlobalKey<NavigatorState>(debugLabel: 'tab:${d.name}'),
  ];
  final _heroControllers = [
    for (final _ in _destinations) MaterialApp.createMaterialHeroController(),
  ];

  // Dev / screenshot builds can open on another tab:
  // --dart-define=LEKIS_START_TAB=library
  static const _startTab = String.fromEnvironment('LEKIS_START_TAB');

  LekisDestination _current = LekisDestination.values.firstWhere(
    (d) => d.name == _startTab,
    orElse: () => LekisDestination.home,
  );

  NavigatorState? get _currentNavigator =>
      _navigatorKeys[_current.index].currentState;

  StreamSubscription<void>? _widgetOpen;

  @override
  void initState() {
    super.initState();
    // 点按 Android 桌面小组件 → 打开正在播放页。
    _widgetOpen = homeWidgetOpenRequests.listen((_) {
      if (mounted) unawaited(openNowPlaying(context));
    });
  }

  @override
  void dispose() {
    unawaited(_widgetOpen?.cancel());
    for (final c in _heroControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _select(LekisDestination destination) {
    if (destination == LekisDestination.settings) {
      // 用户点进设置页时每天最多自动检测一次更新，当天不再重复触发。
      unawaited(ref.read(appUpdaterProvider.notifier).checkOncePerDay());
    }
    if (destination == _current) {
      // Re-selecting the active tab returns to its root.
      _currentNavigator?.popUntil((route) => route.isFirst);
      return;
    }
    setState(() => _current = destination);
  }

  void _openAddSource() {
    _select(LekisDestination.sources);
    _currentNavigator?.popUntil(
      (route) => route.isFirst && !route.willHandlePopInternally,
    );
    _sourcesPageKey.currentState?.addSource();
  }

  void _onSystemBack(bool didPop, Object? _) {
    if (didPop) return;
    final navigator = _currentNavigator;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
    } else if (_current != LekisDestination.home) {
      setState(() => _current = LekisDestination.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabCanPop = _currentNavigator?.canPop() ?? false;

    final tabs = KeyedSubtree(
      key: _tabsKey,
      child: NotificationListener<NavigationNotification>(
        // Nested navigators report push/pop here; rebuild so the PopScope
        // below knows whether back belongs to the tab or the app.
        onNotification: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
          return false;
        },
        child: IndexedStack(
          index: _current.index,
          sizing: StackFit.expand,
          children: [
            for (final d in _destinations)
              _TabNavigator(
                key: ValueKey(d),
                page: d.buildPage(sourcesPageKey: _sourcesPageKey),
                active: d == _current,
                navigatorKey: _navigatorKeys[d.index],
                heroController: _heroControllers[d.index],
              ),
          ],
        ),
      ),
    );

    final navPos = ref.watch(navBarPositionProvider);
    final mode = _chromeModeOf(context, navPos);
    final content = ShellChrome(mode: mode, navPosition: navPos, child: tabs);
    return PopScope<Object?>(
      canPop: _current == LekisDestination.home && !tabCanPop,
      onPopInvokedWithResult: _onSystemBack,
      // Starts Connect once (listen + advertise + browse) and shows the
      // pairing code when another device asks to pair with this one.
      child: DesktopLyricsRuntimeHost(
        child: ConnectRuntimeHost(
          child: switch (mode) {
            ShellChromeMode.bottomBar => _BottomBarLayout(
              current: _current,
              onSelected: _select,
              content: content,
            ),
            ShellChromeMode.sideTabs => _SideTabsLayout(
              current: _current,
              onSelected: _select,
              position: navPos,
              content: content,
            ),
            ShellChromeMode.rail => _RailLayout(
              current: _current,
              onSelected: _select,
              content: content,
            ),
            ShellChromeMode.sidebar => _SidebarLayout(
              current: _current,
              onSelected: _select,
              content: content,
            ),
          },
        ),
      ),
    );
  }
}

/// One tab: a nested navigator whose root is the destination page.
class _TabNavigator extends StatelessWidget {
  const _TabNavigator({
    super.key,
    required this.page,
    required this.active,
    required this.navigatorKey,
    required this.heroController,
  });

  final Widget page;
  final bool active;
  final GlobalKey<NavigatorState> navigatorKey;
  final HeroController heroController;

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: active,
      child: HeroMode(
        enabled: active,
        child: ExcludeFocus(
          excluding: !active,
          child: HeroControllerScope(
            controller: heroController,
            child: Navigator(
              key: navigatorKey,
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => page,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps the mini player / player bar so a tap anywhere not handled by its
/// own controls opens Now Playing.
class _OpensNowPlaying extends StatelessWidget {
  const _OpensNowPlaying({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.deferToChild,
    onTap: () => openNowPlaying(context),
    onVerticalDragEnd: (details) {
      // Swipe up on the player also opens Now Playing.
      if ((details.primaryVelocity ?? 0) < 0) openNowPlaying(context);
    },
    child: child,
  );
}

class _BottomBarLayout extends ConsumerWidget {
  const _BottomBarLayout({
    required this.current,
    required this.onSelected,
    required this.content,
  });

  final LekisDestination current;
  final ValueChanged<LekisDestination> onSelected;
  final Widget content;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(tabBarStyleProvider);
    return Scaffold(
      // The mini player and the glass tab bar float over the content: pages
      // scroll underneath (that is what the glass blurs) and Scaffold adds
      // the chrome height to MediaQuery.padding.bottom so the last item
      // still scrolls clear (see scrollEndPadding).
      extendBody: true,
      body: content,
      bottomNavigationBar: _BottomChromeFade(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A slim capsule exactly as wide as the tab capsule below it, with
            // a gap between them: two stacked pills, not one crowded slab.
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LekisSpacing.lg - LekisSizes.miniPlayerMargin,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth:
                        LekisTabBarTokens.maxSlotWidth *
                            LekisDestination.values.length +
                        LekisTabBarTokens.innerInset * 2 +
                        LekisSizes.miniPlayerMargin * 2,
                  ),
                  child: const _OpensNowPlaying(child: MiniPlayer()),
                ),
              ),
            ),
            LekisTabBar(
              selected: current,
              onSelected: onSelected,
              style: style,
            ),
          ],
        ),
      ),
    );
  }
}

/// Telegram's main-tabs fade: the page dissolves into its own background
/// over [_fade] dp above the floating chrome, so scrolling content never
/// collides with the capsules' edges and no big drop shadow is needed to
/// separate them.
class _BottomChromeFade extends StatelessWidget {
  const _BottomChromeFade({required this.child});

  final Widget child;

  static const double _fade = 60;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: -_fade / 2,
          bottom: 0,
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (context, c) {
                final solid = (_fade / c.maxHeight).clamp(0.0, 1.0);
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        bg.withValues(alpha: 0),
                        bg.withValues(alpha: 0.72),
                        bg.withValues(alpha: 0.88),
                      ],
                      stops: [0, solid, 1],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// 侧边悬浮玻璃导航栏（左 / 右），参照 Apple iPhone Duo 非对称安全区（asymmetric
/// safeAreaInsets）设计：
/// - 页面根容器始终全宽铺满（不做硬裁切），首页横滑画廊与快捷胶囊直接从透明玻璃下穿过折射；
/// - 通过 [MediaQuery.padding] 向导航栏所在侧注入非对称安全区，使全应用所有静态按钮、
///   列表尾标、设置开关、Hero 播放键与 A–Z 索引条自动避让，零遮挡。
class _SideTabsLayout extends ConsumerWidget {
  const _SideTabsLayout({
    required this.current,
    required this.onSelected,
    required this.position,
    required this.content,
  });

  final LekisDestination current;
  final ValueChanged<LekisDestination> onSelected;
  final NavBarPosition position;
  final Widget content;

  /// 竖向悬浮胶囊自身宽度 + 边缘间距 + 呼吸留白（注入到对应侧的 SafeArea）。
  static const double sideSafeInset =
      LekisTabBarTokens.height + LekisSpacing.md + LekisSpacing.sm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(tabBarStyleProvider);
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    final hasRemote = ref.watch(activeRemoteProvider) != null;
    final mq = MediaQuery.of(context);
    // Reserve the band the floating mini player really occupies (card +
    // margin + gesture inset), not just the card.
    final mini = (hasTrack || hasRemote)
        ? MiniPlayer.bottomBandHeight(context)
        : 0.0;
    final isLeft = position == NavBarPosition.left;
    return Scaffold(
      // The content below gets a MediaQuery read from *outside* this
      // Scaffold, i.e. still carrying the keyboard inset. If this Scaffold
      // also shrank for the keyboard, the page's own Scaffold would subtract
      // it a second time and a form with the keyboard up (Sources > Add >
      // host) went blank on the Fold5. Leave the keyboard to the page.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 全宽绘制 + 非对称安全区：静态交互区自动避让，横向滚动流可无裁切穿过玻璃。
          Positioned.fill(
            child: MediaQuery(
              data: mq.copyWith(
                padding: mq.padding.copyWith(
                  left: isLeft
                      ? mq.padding.left + sideSafeInset
                      : mq.padding.left,
                  right: isLeft
                      ? mq.padding.right
                      : mq.padding.right + sideSafeInset,
                  bottom: mq.padding.bottom + mini,
                ),
              ),
              child: content,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: LekisSizes.floatingMiniPlayerMaxWidth,
                ),
                child: const _OpensNowPlaying(
                  child: MiniPlayer(atBottomEdge: true),
                ),
              ),
            ),
          ),
          Positioned(
            top: mq.padding.top,
            bottom: mini > 0 ? mini : mq.padding.bottom,
            left: isLeft ? LekisSpacing.md + mq.padding.left : null,
            right: isLeft ? null : LekisSpacing.md + mq.padding.right,
            child: Center(
              child: LekisTabBar(
                key: ValueKey('side-tab-bar.${position.storageValue}'),
                selected: current,
                onSelected: onSelected,
                style: style,
                axis: Axis.vertical,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailLayout extends StatelessWidget {
  const _RailLayout({
    required this.current,
    required this.onSelected,
    required this.content,
  });

  final LekisDestination current;
  final ValueChanged<LekisDestination> onSelected;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The content below gets a MediaQuery read from *outside* this
      // Scaffold, i.e. still carrying the keyboard inset. If this Scaffold
      // also shrank for the keyboard, the page's own Scaffold would subtract
      // it a second time and a form with the keyboard up (Sources > Add >
      // host) went blank on the Fold5. Leave the keyboard to the page.
      resizeToAvoidBottomInset: false,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LekisNavRail(selected: current, onSelected: onSelected),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: MediaQuery.removePadding(
                    context: context,
                    removeLeft: true,
                    removeBottom: true,
                    child: content,
                  ),
                ),
                // The mini player keeps clear of the gesture area itself
                // (and reserves it when nothing is playing).
                const SafeArea(
                  top: false,
                  left: false,
                  bottom: false,
                  child: MiniPlayer(atBottomEdge: true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Desktop (Spotify / Apple Music): sidebar | content | optional context
/// panel, with the persistent player bar along the whole bottom edge.
class _SidebarLayout extends StatelessWidget {
  const _SidebarLayout({
    required this.current,
    required this.onSelected,
    required this.content,
  });

  final LekisDestination current;
  final ValueChanged<LekisDestination> onSelected;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    // Room for content plus the 320 dp lyrics / queue panel.
    final sidePanel = context.widthClass >= WindowWidthClass.large;
    return Scaffold(
      // The content below gets a MediaQuery read from *outside* this
      // Scaffold, i.e. still carrying the keyboard inset. If this Scaffold
      // also shrank for the keyboard, the page's own Scaffold would subtract
      // it a second time and a form with the keyboard up (Sources > Add >
      // host) went blank on the Fold5. Leave the keyboard to the page.
      resizeToAvoidBottomInset: false,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LekisSidebar(selected: current, onSelected: onSelected),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeLeft: true,
              removeBottom: true,
              child: content,
            ),
          ),
          if (sidePanel) const NowPlayingContextPanel(),
        ],
      ),
      // As the bottom bar, snack bars float above the player instead of
      // covering it. The bar opens Now Playing from its artwork / title only;
      // its lyrics / queue buttons toggle the context panel when there is
      // room for it.
      bottomNavigationBar: SafeArea(
        top: false,
        child: PlayerBar(sidePanel: sidePanel),
      ),
    );
  }
}
