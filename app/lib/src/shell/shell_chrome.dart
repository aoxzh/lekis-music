// What navigation chrome currently surrounds the tab pages.
//
// Pages read this to avoid duplicating what the chrome already shows (for
// example the brand mark lives in the rail / sidebar on larger windows, so
// the home header only shows it on phones).

import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/layout/window_size.dart';
import 'package:lekis/src/platform/ui_profile.dart';

import 'nav_bar_position.dart';

enum ShellChromeMode {
  /// Phones, foldables and tablets (default), and narrow desktop windows:
  /// floating glass tab bar + mini player over the content.
  bottomBar,

  /// Floating vertical icon glass capsule on the left or right edge over full-bleed content.
  sideTabs,

  /// Short landscape windows: icon rail on the left.
  rail,

  /// Expanded desktop windows only: full sidebar + desktop player bar.
  sidebar,
}

/// Which chrome the shell puts around the tabs for a [size] window.
///
/// The desktop sidebar + player bar is a desktop-profile layout, chosen
/// only when the window is expanded or wider. Mobile profiles keep the
/// phone chrome at every width: an Android tablet (1280 x 800 dp) or an
/// unfolded foldable is still a touch device, so it gets the floating tab
/// bar (or side tabs, per [navPosition]) and the mini player; pages adapt
/// their content to the extra width themselves.
///
/// Short windows (phone landscape, split screen) use the rail on every
/// profile: a bottom bar would eat too much of the height.
ShellChromeMode shellChromeModeFor({
  required Size size,
  required NavBarPosition navPosition,
  UiProfile? profile,
}) {
  if (WindowHeightClass.fromHeight(size.height) == WindowHeightClass.compact) {
    return ShellChromeMode.rail;
  }
  final desktopShell = (profile ?? UiProfile.current).desktopShell;
  if (desktopShell &&
      WindowWidthClass.fromWidth(size.width) >= WindowWidthClass.expanded) {
    return ShellChromeMode.sidebar;
  }
  return navPosition == NavBarPosition.bottom
      ? ShellChromeMode.bottomBar
      : ShellChromeMode.sideTabs;
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
