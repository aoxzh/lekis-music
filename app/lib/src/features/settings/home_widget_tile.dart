// 设置 → 外观：把播放小组件加到 Android 桌面。

import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../platform/android_home_widget.dart';
import '../sources/common.dart';
import 'widgets/settings_widgets.dart';

class HomeWidgetSettingsTile extends StatelessWidget {
  const HomeWidgetSettingsTile({super.key});

  Future<void> _add(BuildContext context) async {
    final l10n = context.l10n;
    final requested = await requestPinPlayerWidget();
    if (!context.mounted || requested) return;
    // 启动器不支持应用内添加：告诉用户手动添加的路径。
    showFeatureSnack(
      context,
      l10n.pick(
        '当前桌面不支持直接添加。请长按桌面空白处 → 小组件 → 月兔音乐。',
        "Your launcher can't add it from here. Long-press the home screen → Widgets → Lekis Music.",
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsTile(
      icon: Icons.widgets_outlined,
      title: l10n.pick('桌面小组件', 'Home screen widget'),
      subtitle: Text(
        l10n.pick(
          '在桌面显示正在播放，可暂停、切歌',
          'Shows what’s playing on your home screen, with playback controls',
        ),
      ),
      trailing: TextButton(
        onPressed: () => _add(context),
        child: Text(l10n.pick('添加', 'Add')),
      ),
      onTap: () => _add(context),
    );
  }
}
