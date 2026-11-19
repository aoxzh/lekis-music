// Adaptive navigation shell.
//
//  * compact width            → floating translucent tab bar + MiniPlayer above it
//  * medium width             → NavigationRail + MiniPlayer under the content
//  * expanded width and up    → sidebar + desktop PlayerBar along the bottom
//  * compact height (any width, e.g. phone landscape) → NavigationRail
//
// Every size has the same destinations; each tab owns a nested Navigator
// kept alive in an IndexedStack, and the whole tab stack sits under one
// GlobalKey so resizing / folding only re-arranges the chrome around it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/features/player/mini_player.dart';
import 'package:lekis/src/features/player/player_bar.dart';
import 'package:lekis/src/layout/window_size.dart';

import 'destinations.dart';
import 'now_playing_context.dart';
import 'routes.dart';
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

enum _ChromeMode { bottomBar, rail, sidebar }

_ChromeMode _chromeModeOf(BuildContext context) {
  if (context.heightClass == WindowHeightClass.compact) return _ChromeMode.rail;
  return switch (context.widthClass) {
    WindowWidthClass.compact => _ChromeMode.bottomBar,
    WindowWidthClass.medium => _ChromeMode.rail,
    _ => _ChromeMode.sidebar,
  };
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Switches the shell to [destination] from anywhere below it.
  static void select(BuildContext context, LekisDestination destination) =>
      context.findAncestorStateOfType<_AppShellState>()?._select(destination);

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const _destinations = LekisDestination.values;

  final _tabsKey = GlobalKey(debugLabel: 'AppShell.tabs');
  final _navigatorKeys = [
    for (final d in _destinations)
      GlobalKey<NavigatorState>(debugLabel: 'tab:${d.name}'),
  ];
  final _heroControllers = [
    for (final _ in _destinations) MaterialApp.createMaterialHeroController(),
  ];

  LekisDestination _current = LekisDestination.home;

  NavigatorState? get _currentNavigator =>
      _navigatorKeys[_current.index].currentState;

  @override
  void dispose() {
    for (final c in _heroControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _select(LekisDestination destination) {
    if (destination == _current) {
      // Re-selecting the active tab returns to its root.
      _currentNavigator?.popUntil((route) => route.isFirst);
      return;
    }
    setState(() => _current = destination);
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
                destination: d,
                active: d == _current,
                navigatorKey: _navigatorKeys[d.index],
                heroController: _heroControllers[d.index],
              ),
          ],
        ),
      ),
    );

    return PopScope<Object?>(
      canPop: _current == LekisDestination.home && !tabCanPop,
      onPopInvokedWithResult: _onSystemBack,
      child: switch (_chromeModeOf(context)) {
        _ChromeMode.bottomBar => _BottomBarLayout(
          current: _current,
          onSelected: _select,
          content: tabs,
        ),
        _ChromeMode.rail => _RailLayout(
          current: _current,
          onSelected: _select,
          content: tabs,
        ),
        _ChromeMode.sidebar => _SidebarLayout(
          current: _current,
          onSelected: _select,
          content: tabs,
        ),
      },
    );
  }
}

/// One tab: a nested navigator whose root is the destination page.
class _TabNavigator extends StatelessWidget {
  const _TabNavigator({
    super.key,
    required this.destination,
    required this.active,
    required this.navigatorKey,
    required this.heroController,
  });

  final LekisDestination destination;
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
                builder: (_) => destination.buildPage(),
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
      body: content,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _OpensNowPlaying(child: MiniPlayer()),
          LekisTabBar(selected: current, onSelected: onSelected, style: style),
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
    final showContext = context.widthClass >= WindowWidthClass.large;
    return Scaffold(
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
          if (showContext) const NowPlayingContextPanel(),
        ],
      ),
      // As the bottom bar, snack bars float above the player instead of
      // covering it. The bar opens Now Playing from its artwork / title only.
      bottomNavigationBar: const SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [Divider(), PlayerBar()],
        ),
      ),
    );
  }
}
