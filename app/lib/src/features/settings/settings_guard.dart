// 设置写入失败时的统一提示。

import 'package:material_ui/material_ui.dart';

import '../sources/common.dart';
import 'strings.dart';

/// 执行一次设置写入；失败时弹出“保存设置失败”提示，不向上抛。
Future<void> settingsGuard(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      showFeatureSnack(
        context,
        '${SettingsStrings.saveFailed}：${describeCoreError(e)}',
      );
    }
  }
}
