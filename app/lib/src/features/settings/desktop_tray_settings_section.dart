// Windows-only settings for the notification-area icon and close behaviour.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../sources/common.dart';
import 'desktop_tray_settings.dart';
import 'strings.dart';
import 'widgets/settings_widgets.dart';

class DesktopTraySettingsSection extends ConsumerWidget {
  const DesktopTraySettingsSection({super.key});

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isSupported) return const SizedBox.shrink();

    final settings = ref.watch(desktopTraySettingsProvider);
    final notifier = ref.read(desktopTraySettingsProvider.notifier);
    Future<void> save(Future<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        if (context.mounted) {
          showFeatureSnack(
            context,
            '${SettingsStrings.saveFailed}：${describeCoreError(error)}',
          );
        }
      }
    }

    return SettingsSection(
      title: SettingsStrings.system,
      children: [
        KeyedSubtree(
          key: const ValueKey('desktop-tray-enabled'),
          child: SettingsSwitchTile(
            icon: Icons.notifications_none_rounded,
            title: SettingsStrings.desktopTrayEnabled,
            subtitle: SettingsStrings.desktopTrayEnabledHint,
            value: settings.trayEnabled,
            onChanged: (value) => save(() => notifier.setTrayEnabled(value)),
          ),
        ),
        KeyedSubtree(
          key: const ValueKey('desktop-tray-close-to-tray'),
          child: SettingsSwitchTile(
            icon: Icons.close_fullscreen_rounded,
            title: SettingsStrings.desktopTrayCloseToTray,
            subtitle: settings.trayEnabled
                ? SettingsStrings.desktopTrayCloseToTrayHint
                : SettingsStrings.desktopTrayNeedsIcon,
            value: settings.closeToTray,
            onChanged: settings.trayEnabled
                ? (value) => save(() => notifier.setCloseToTray(value))
                : null,
          ),
        ),
      ],
    );
  }
}
