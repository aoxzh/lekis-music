// 默认社区目录开关：插件页的目录区和设置 › 插件里都用这一行。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../settings/widgets/settings_widgets.dart';
import 'plugin_sources.dart';
import 'strings.dart';

class PluginBuiltinSourceTile extends ConsumerWidget {
  const PluginBuiltinSourceTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(pluginBuiltinSourceEnabledProvider);
    return SettingsSwitchTile(
      icon: Icons.public_rounded,
      title: PluginStrings.builtinSourceToggle,
      subtitle: PluginStrings.builtinSourceHint,
      value: enabled.value ?? true,
      onChanged: enabled.hasValue
          ? (value) => ref
                .read(pluginBuiltinSourceEnabledProvider.notifier)
                .setEnabled(value)
          : null,
    );
  }
}
