// Windows desktop integration settings: tray icon and close-to-tray.
//
// The two switches are intentionally independent values in the core settings
// store. `close_to_tray` only takes effect while the tray icon exists, so
// turning the tray off can never leave a hidden window with no way back.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/core.dart' as core;

abstract final class DesktopTraySettingKeys {
  static const trayEnabled = 'desktop.tray.enabled';
  static const closeToTray = 'desktop.close_to_tray';
}

@immutable
class DesktopTraySettings {
  const DesktopTraySettings({this.trayEnabled = true, this.closeToTray = true});

  /// Show the Windows notification-area icon.
  final bool trayEnabled;

  /// Hide the window instead of exiting when the user clicks the close button.
  final bool closeToTray;

  static bool parseBool(String? raw, {required bool fallback}) {
    if (raw == null) return fallback;
    return switch (raw.trim().toLowerCase()) {
      'true' || '1' || 'on' || 'yes' => true,
      'false' || '0' || 'off' || 'no' => false,
      _ => fallback,
    };
  }

  static String encodeBool(bool value) => value ? 'true' : 'false';

  static DesktopTraySettings fromStorage({
    String? trayEnabled,
    String? closeToTray,
  }) {
    return DesktopTraySettings(
      trayEnabled: parseBool(
        trayEnabled,
        fallback: const DesktopTraySettings().trayEnabled,
      ),
      closeToTray: parseBool(
        closeToTray,
        fallback: const DesktopTraySettings().closeToTray,
      ),
    );
  }

  DesktopTraySettings copyWith({bool? trayEnabled, bool? closeToTray}) {
    return DesktopTraySettings(
      trayEnabled: trayEnabled ?? this.trayEnabled,
      closeToTray: closeToTray ?? this.closeToTray,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopTraySettings &&
      other.trayEnabled == trayEnabled &&
      other.closeToTray == closeToTray;

  @override
  int get hashCode => Object.hash(trayEnabled, closeToTray);
}

final desktopTraySettingsProvider =
    NotifierProvider<DesktopTraySettingsNotifier, DesktopTraySettings>(
      DesktopTraySettingsNotifier.new,
    );

class DesktopTraySettingsNotifier extends Notifier<DesktopTraySettings> {
  @override
  DesktopTraySettings build() => const DesktopTraySettings();

  /// Startup restore; does not write back to the core.
  void restore(DesktopTraySettings value) => state = value;

  Future<void> setTrayEnabled(bool value) async {
    if (state.trayEnabled == value) return;
    final previous = state;
    state = state.copyWith(trayEnabled: value);
    try {
      await core.setSetting(
        key: DesktopTraySettingKeys.trayEnabled,
        value: DesktopTraySettings.encodeBool(value),
      );
    } catch (_) {
      state = previous;
      rethrow;
    }
  }

  Future<void> setCloseToTray(bool value) async {
    if (state.closeToTray == value) return;
    final previous = state;
    state = state.copyWith(closeToTray: value);
    try {
      await core.setSetting(
        key: DesktopTraySettingKeys.closeToTray,
        value: DesktopTraySettings.encodeBool(value),
      );
    } catch (_) {
      state = previous;
      rethrow;
    }
  }
}

/// Reads both switches before the first frame. Missing values keep defaults.
Future<void> restoreDesktopTraySettings(ProviderContainer container) async {
  try {
    final values = await Future.wait([
      core.getSetting(key: DesktopTraySettingKeys.trayEnabled),
      core.getSetting(key: DesktopTraySettingKeys.closeToTray),
    ]);
    container
        .read(desktopTraySettingsProvider.notifier)
        .restore(
          DesktopTraySettings.fromStorage(
            trayEnabled: values[0],
            closeToTray: values[1],
          ),
        );
  } catch (error) {
    debugPrint('restore desktop tray settings failed: $error');
  }
}
