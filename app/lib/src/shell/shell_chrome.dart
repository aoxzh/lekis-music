// What navigation chrome currently surrounds the tab pages.
//
// Pages read this to avoid duplicating what the chrome already shows (for
// example the brand mark lives in the rail / sidebar on larger windows, so
// the home header only shows it on phones).

import 'package:material_ui/material_ui.dart';

enum ShellChromeMode {
  /// Phones: floating glass tab bar + mini player over the content.
  bottomBar,

  /// Medium windows / short landscape: icon rail on the left.
  rail,

  /// Expanded windows: full sidebar + desktop player bar.
  sidebar,
}

class ShellChrome extends InheritedWidget {
  const ShellChrome({super.key, required this.mode, required super.child});

  final ShellChromeMode mode;

  /// The rail and sidebar already show the Lekis mark.
  bool get showsBrandMark => mode != ShellChromeMode.bottomBar;

  /// Pages outside the shell (tests, routes pushed on the root navigator)
  /// behave as if on a phone.
  static ShellChromeMode modeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellChrome>()?.mode ??
      ShellChromeMode.bottomBar;

  static bool showsBrandMarkOf(BuildContext context) =>
      modeOf(context) != ShellChromeMode.bottomBar;

  @override
  bool updateShouldNotify(ShellChrome oldWidget) => oldWidget.mode != mode;
}
