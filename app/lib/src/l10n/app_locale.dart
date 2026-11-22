// 应用语言偏好：跟随系统 / 简体中文 / English。
//
// 持久化到核心设置库（`ui.locale`），首帧前恢复，切换后整套界面实时生效。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../rust/api/core.dart' as core;

const String appLocaleSettingKey = 'ui.locale';

enum AppLocalePreference {
  system('system'),
  zh('zh'),
  en('en');

  const AppLocalePreference(this.storageValue);

  final String storageValue;

  Locale? get locale => switch (this) {
    AppLocalePreference.system => null,
    AppLocalePreference.zh => const Locale('zh', 'CN'),
    AppLocalePreference.en => const Locale('en', 'US'),
  };

  static AppLocalePreference fromStorage(String? value) => values.firstWhere(
    (p) => p.storageValue == value,
    orElse: () => AppLocalePreference.system,
  );
}

final appLocaleProvider =
    NotifierProvider<AppLocaleNotifier, AppLocalePreference>(
      AppLocaleNotifier.new,
    );

class AppLocaleNotifier extends Notifier<AppLocalePreference> {
  @override
  AppLocalePreference build() => AppLocalePreference.system;

  Future<void> set(AppLocalePreference value) async {
    if (state == value) return;
    final previous = state;
    state = value;
    try {
      await core.setSetting(
        key: appLocaleSettingKey,
        value: value.storageValue,
      );
    } catch (_) {
      state = previous;
      rethrow;
    }
  }

  void restore(AppLocalePreference value) => state = value;
}

Future<void> restoreAppLocale(ProviderContainer container) async {
  try {
    final raw = await core.getSetting(key: appLocaleSettingKey);
    if (raw == null) return;
    container
        .read(appLocaleProvider.notifier)
        .restore(AppLocalePreference.fromStorage(raw));
  } catch (_) {}
}
