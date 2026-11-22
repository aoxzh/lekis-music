// What navigation chrome currently surrounds the tab pages.
//
// Pages read this to avoid duplicating what the chrome already shows (for
// example the brand mark lives in the rail / sidebar on larger windows, so
// the home header only shows it on phones).

import 'package:material_ui/material_ui.dart';

import 'nav_bar_position.dart';

enum ShellChromeMode {
  /// Phones & foldables (default): floating glass tab bar + mini player over the content.
  bottomBar,

  /// Floating vertical icon glass capsule on the left or right edge over full-bleed content.
  sideTabs,

  /// Short landscape windows: icon rail on the left.
  rail,

  /// Expanded windows: full sidebar + desktop player bar.
  sidebar,
}

class ShellChrome extends InheritedWidget {
  const ShellChrome({
    super.key,
    required this.mode,
    this.navPosition = NavBarPosition.bottom,
    required super.child,
  });

  final ShellChromeMode mode;
  final NavBarPosition navPosition;

  /// The rail and sidebar already show the Lekis mark.
  bool get showsBrandMark =>
      mode == ShellChromeMode.rail || mode == ShellChromeMode.sidebar;

  /// Pages outside the shell (tests, routes pushed on the root navigator)
  /// behave as if on a phone.
  static ShellChromeMode modeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellChrome>()?.mode ??
      ShellChromeMode.bottomBar;

  static NavBarPosition navPositionOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellChrome>()?.navPosition ??
      NavBarPosition.bottom;

  static bool hasFloatingRightNavOf(BuildContext context) {
    final chrome = context.dependOnInheritedWidgetOfExactType<ShellChrome>();
    return chrome != null &&
        chrome.mode == ShellChromeMode.sideTabs &&
        chrome.navPosition == NavBarPosition.right;
  }

  static bool showsBrandMarkOf(BuildContext context) =>
      switch (modeOf(context)) {
        ShellChromeMode.rail || ShellChromeMode.sidebar => true,
        _ => false,
      };

  @override
  bool updateShouldNotify(ShellChrome oldWidget) =>
      oldWidget.mode != mode || oldWidget.navPosition != navPosition;
}
