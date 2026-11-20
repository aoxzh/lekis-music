// Bottom tab bar appearance: liquid glass (default) or flat.
//
// The choice only exists on mobile. Desktop profiles have no glass, so the
// setting is hidden there and [TabBarStyleResolve.resolved] always yields
// flat (a saved `liquid`, e.g. from a restored backup, is ignored).
//
// The preference is stored in the core settings store so it survives
// restarts. The app restores it before the first frame; a failed read or an
// unknown value falls back to liquid glass.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/ui_profile.dart';
import '../rust/api/core.dart' as core;

/// Core setting key for the tab bar style.
const String tabBarStyleSettingKey = 'ui.tabbar_style';

enum TabBarStyle {
  liquid('liquid'),
  flat('flat');

  const TabBarStyle(this.storageValue);

  final String storageValue;

  static TabBarStyle fromStorage(String? value) => values.firstWhere(
    (style) => style.storageValue == value,
    orElse: () => TabBarStyle.liquid,
  );
}

extension TabBarStyleResolve on TabBarStyle {
  /// The style actually drawn on this device: flat wherever the profile
  /// has no glass materials.
  TabBarStyle get resolved =>
      UiProfile.current.offersTabBarStyle ? this : TabBarStyle.flat;
}

/// Live tab bar style. Defaults to liquid glass until restored.
final tabBarStyleProvider = NotifierProvider<TabBarStyleNotifier, TabBarStyle>(
  TabBarStyleNotifier.new,
);

class TabBarStyleNotifier extends Notifier<TabBarStyle> {
  @override
  TabBarStyle build() => TabBarStyle.liquid;

  /// Applies the style optimistically, then persists it. A failed write
  /// rolls the UI back so the bar never claims a style the core rejected.
  Future<void> set(TabBarStyle value) async {
    if (state == value) return;
    final previous = state;
    state = value;
    try {
      await core.setSetting(
        key: tabBarStyleSettingKey,
        value: value.storageValue,
      );
    } catch (_) {
      state = previous;
      rethrow;
    }
  }

  /// Startup restore; does not write back to the core.
  void restore(TabBarStyle value) => state = value;
}

/// Reads the saved style before [runApp]. Null and errors keep the default.
Future<void> restoreTabBarStyle(ProviderContainer container) async {
  try {
    final raw = await core.getSetting(key: tabBarStyleSettingKey);
    if (raw == null) return;
    container
        .read(tabBarStyleProvider.notifier)
        .restore(TabBarStyle.fromStorage(raw));
  } catch (_) {}
}
