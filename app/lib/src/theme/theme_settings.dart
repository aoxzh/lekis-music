// In-memory appearance settings. Defaults follow the system; the settings
// page may change them (persisting via the core's `setSetting` is up to it).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// Light / dark / system. Defaults to [ThemeMode.system].
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.system;

  void set(ThemeMode mode) => state = mode;
}

/// Whether the dark theme uses pure-black (OLED) surfaces.
final oledBlackProvider = NotifierProvider<OledBlackNotifier, bool>(
  OledBlackNotifier.new,
);

class OledBlackNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}
