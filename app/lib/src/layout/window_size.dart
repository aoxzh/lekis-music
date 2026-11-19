// Window size classes (Material 3 adaptive breakpoints). Always derived from
// the current window size, never from the device type, so desktop windows,
// split-screen, foldables and freeform windows all behave the same way.

import 'package:material_ui/material_ui.dart';

/// Width class: <600, <840, <1200, <1600, >=1600 dp.
enum WindowWidthClass {
  compact,
  medium,
  expanded,
  large,
  extraLarge;

  static WindowWidthClass fromWidth(double width) {
    if (width < 600) return compact;
    if (width < 840) return medium;
    if (width < 1200) return expanded;
    if (width < 1600) return large;
    return extraLarge;
  }

  bool operator >=(WindowWidthClass other) => index >= other.index;
  bool operator <(WindowWidthClass other) => index < other.index;
}

/// Height class: <480, <900, >=900 dp.
enum WindowHeightClass {
  compact,
  medium,
  expanded;

  static WindowHeightClass fromHeight(double height) {
    if (height < 480) return compact;
    if (height < 900) return medium;
    return expanded;
  }

  bool operator >=(WindowHeightClass other) => index >= other.index;
  bool operator <(WindowHeightClass other) => index < other.index;
}

extension WindowSizeX on BuildContext {
  /// Width class of the current window (rebuilds only on size changes).
  WindowWidthClass get widthClass =>
      WindowWidthClass.fromWidth(MediaQuery.sizeOf(this).width);

  /// Height class of the current window (rebuilds only on size changes).
  WindowHeightClass get heightClass =>
      WindowHeightClass.fromHeight(MediaQuery.sizeOf(this).height);
}
