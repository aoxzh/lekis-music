// What kind of device the UI is running on, and what that device's UI can
// and should do.
//
// One place decides "desktop vs mobile" so pages never test for Windows /
// macOS / Linux / Android themselves. Everything that differs between the
// two experiences reads a capability from here:
//
//   * mobile  (Android, iOS): glass materials, bottom sheets, haptics,
//     touch density, the tab bar style choice, system volume keys.
//   * desktop (Windows, macOS, Linux): flat opaque Fluent-like surfaces,
//     dialogs and context menus instead of sheets, hover / right-click /
//     tooltips, compact mouse density, no options that only change mobile
//     chrome.
//
// Options that have no effect (or do not fit) on the current profile are
// hidden, not disabled. Adding macOS or Linux later needs no page changes:
// they get the desktop profile automatically.
//
// Tests switch profiles with [UiProfile.debugOverride] (remember to reset it
// in `addTearDown`).

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// The two experiences the app is designed for.
enum UiFormFactor { mobile, desktop }

@immutable
class UiProfile {
  const UiProfile({
    required this.formFactor,
    required this.supportsHaptics,
    this.supportsTray = false,
  });

  /// Phones, foldables and tablets.
  static const mobile = UiProfile(
    formFactor: UiFormFactor.mobile,
    supportsHaptics: true,
  );

  /// Windows, macOS and Linux.
  static const desktop = UiProfile(
    formFactor: UiFormFactor.desktop,
    supportsHaptics: false,
  );

  /// The profile for [platform]. Web follows its host platform's family.
  static UiProfile forPlatform(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => mobile,
    // The notification-area icon is implemented for Windows only so far.
    TargetPlatform.windows => const UiProfile(
      formFactor: UiFormFactor.desktop,
      supportsHaptics: false,
      supportsTray: !kIsWeb,
    ),
    TargetPlatform.macOS || TargetPlatform.linux => desktop,
  };

  /// Test hook: forces a profile until reset to `null`.
  static UiProfile? debugOverride;

  /// The profile of the running app.
  static UiProfile get current =>
      debugOverride ?? forPlatform(defaultTargetPlatform);

  final UiFormFactor formFactor;

  /// The platform has a haptic engine worth using for selection ticks.
  final bool supportsHaptics;

  /// A notification-area / menu-bar icon is implemented on this platform.
  final bool supportsTray;

  bool get isDesktop => formFactor == UiFormFactor.desktop;
  bool get isMobile => formFactor == UiFormFactor.mobile;

  /// Translucent blurred ("liquid glass") materials: tab bar, mini player,
  /// sheets and menus over artwork. Desktop uses flat opaque surfaces.
  bool get supportsGlass => isMobile;

  /// The liquid / flat tab bar choice only exists where the glass bar does.
  bool get offersTabBarStyle => supportsGlass;

  /// Transient choices and editors open as bottom sheets (mobile) or as
  /// dialogs, popup and context menus (desktop).
  bool get prefersSheets => isMobile;

  /// Mouse and keyboard first: hover states, right-click context menus,
  /// tooltips, scroll arrows, Ctrl+F.
  bool get pointerFirst => isDesktop;

  /// Hardware volume keys and a system volume UI exist, so the app shows no
  /// volume slider of its own.
  bool get hasSystemVolume => isMobile;

  /// Settings use the Windows-11-style list + detail with cards, dropdowns
  /// and labelled toggles.
  bool get desktopSettings => isDesktop;

  /// Default density for controls: compact for a mouse, standard for touch.
  VisualDensity get visualDensity =>
      isDesktop ? VisualDensity.compact : VisualDensity.standard;

  MaterialTapTargetSize get tapTargetSize => isDesktop
      ? MaterialTapTargetSize.shrinkWrap
      : MaterialTapTargetSize.padded;

  @override
  bool operator ==(Object other) =>
      other is UiProfile &&
      other.formFactor == formFactor &&
      other.supportsHaptics == supportsHaptics &&
      other.supportsTray == supportsTray;

  @override
  int get hashCode => Object.hash(formFactor, supportsHaptics, supportsTray);

  @override
  String toString() => 'UiProfile(${formFactor.name})';
}

/// Selection tick for tab switches, swipes and snaps. Silent on desktop.
void lekisSelectionHaptic() {
  if (UiProfile.current.supportsHaptics) HapticFeedback.selectionClick();
}
