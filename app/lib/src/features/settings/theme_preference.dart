// 外观偏好：系统 / 浅色 / 深色 / OLED 纯黑。
//
// 运行时状态在 `theme/theme_settings.dart` 的 `themeModeProvider` + `oledBlackProvider`
// （应用外壳读取它们）；这里负责两者与核心设置项 `ui.theme` 之间的读写。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/core.dart' as core;
import '../../theme/theme_settings.dart';

/// 设置项键名。值：`system` / `light` / `dark` / `oled`。
const String themeSettingKey = 'ui.theme';

/// 强调色预设的键名，值为 [LekisAccent.id]。
const String accentSettingKey = 'ui.accent';

enum ThemePreference {
  system('system', ThemeMode.system, false),
  light('light', ThemeMode.light, false),
  dark('dark', ThemeMode.dark, false),
  oledBlack('oled', ThemeMode.dark, true);

  const ThemePreference(this.storageValue, this.themeMode, this.usesOledBlack);

  final String storageValue;
  final ThemeMode themeMode;
  final bool usesOledBlack;

  static ThemePreference fromStorage(String? value) => values.firstWhere(
    (p) => p.storageValue == value,
    orElse: () => ThemePreference.system,
  );

  static ThemePreference of(ThemeMode mode, bool oled) => switch (mode) {
    ThemeMode.light => light,
    ThemeMode.dark => oled ? oledBlack : dark,
    ThemeMode.system => system,
  };
}

/// 当前外观偏好（由两个底层 provider 合成，只读）。
final themePreferenceProvider = Provider<ThemePreference>(
  (ref) => ThemePreference.of(
    ref.watch(themeModeProvider),
    ref.watch(oledBlackProvider),
  ),
);

void _apply(
  ThemeModeNotifier mode,
  OledBlackNotifier oled,
  ThemePreference pref,
) {
  mode.set(pref.themeMode);
  oled.set(pref.usesOledBlack);
}

/// 启动时从核心读回保存的外观偏好。核心未初始化或读取失败时保持默认（跟随系统）。
Future<void> restoreThemePreference(ProviderContainer container) async {
  final pref = await _load();
  final accent = await _loadAccent();
  if (accent != null) {
    container.read(accentProvider.notifier).set(accent);
  }
  if (pref == null) return;
  _apply(
    container.read(themeModeProvider.notifier),
    container.read(oledBlackProvider.notifier),
    pref,
  );
}

/// 同上，供只能拿到 [WidgetRef] 的地方调用。
Future<void> restoreThemePreferenceWithRef(WidgetRef ref) async {
  final pref = await _load();
  final accent = await _loadAccent();
  if (accent != null) ref.read(accentProvider.notifier).set(accent);
  if (pref == null) return;
  _apply(
    ref.read(themeModeProvider.notifier),
    ref.read(oledBlackProvider.notifier),
    pref,
  );
}

Future<ThemePreference?> _load() async {
  try {
    final raw = await core.getSetting(key: themeSettingKey);
    return raw == null ? null : ThemePreference.fromStorage(raw);
  } catch (_) {
    return null;
  }
}

Future<LekisAccent?> _loadAccent() async {
  try {
    final raw = await core.getSetting(key: accentSettingKey);
    return raw == null ? null : LekisAccent.fromStorage(raw);
  } catch (_) {
    return null;
  }
}

/// 立即切换外观，再写进核心（跨设备同步由核心负责）。写入失败时抛出核心错误，
/// 但界面已经切换，不回滚。
Future<void> setThemePreference(WidgetRef ref, ThemePreference pref) async {
  _apply(
    ref.read(themeModeProvider.notifier),
    ref.read(oledBlackProvider.notifier),
    pref,
  );
  await core.setSetting(key: themeSettingKey, value: pref.storageValue);
}

/// 切换强调色并写入核心设置。
Future<void> setAccentPreference(WidgetRef ref, LekisAccent accent) async {
  ref.read(accentProvider.notifier).set(accent);
  await core.setSetting(key: accentSettingKey, value: accent.id);
}
