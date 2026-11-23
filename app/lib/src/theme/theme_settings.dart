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

/// Accent presets. [moonrise] keeps the original brand palette exactly.
enum LekisAccent {
  moonrise('moonrise', Color(0xFF4F46C8), Color(0xFF6E5BF0)),
  ocean('ocean', Color(0xFF1D4ED8), Color(0xFF60A5FA)),
  forest('forest', Color(0xFF15803D), Color(0xFF4ADE80)),
  rose('rose', Color(0xFFBE123C), Color(0xFFFB7185)),
  amber('amber', Color(0xFFB45309), Color(0xFFFBBF24));

  const LekisAccent(this.id, this.light, this.dark);

  final String id;
  final Color light;
  final Color dark;

  Color colorFor(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  static LekisAccent fromStorage(String? value) =>
      values.firstWhere((accent) => accent.id == value, orElse: () => moonrise);
}

/// Selected accent preset; persisted through `ui.accent`.
final accentProvider = NotifierProvider<AccentNotifier, LekisAccent>(
  AccentNotifier.new,
);

class AccentNotifier extends Notifier<LekisAccent> {
  @override
  LekisAccent build() => LekisAccent.moonrise;

  void set(LekisAccent value) => state = value;
}
