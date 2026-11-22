// 移动端与折叠屏导航栏位置：底部（默认，类似 Apple Music）、左侧或右侧悬浮玻璃。
//
// 仅在移动端 / 折叠屏中等宽度生效；桌面宽屏始终使用完整侧边栏，不展示此选项。
// 偏好持久化在核心设置库，首帧前恢复，避免启动闪烁。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/core.dart' as core;

/// 核心设置键：导航栏位置。
const String navBarPositionSettingKey = 'ui.nav_position';

enum NavBarPosition {
  bottom('bottom'),
  left('left'),
  right('right');

  const NavBarPosition(this.storageValue);

  final String storageValue;

  static NavBarPosition fromStorage(String? value) => values.firstWhere(
    (pos) => pos.storageValue == value,
    orElse: () => NavBarPosition.bottom,
  );
}

final navBarPositionProvider =
    NotifierProvider<NavBarPositionNotifier, NavBarPosition>(
      NavBarPositionNotifier.new,
    );

class NavBarPositionNotifier extends Notifier<NavBarPosition> {
  @override
  NavBarPosition build() => NavBarPosition.bottom;

  /// 乐观更新并持久化；写入失败时回滚状态。
  Future<void> set(NavBarPosition value) async {
    if (state == value) return;
    final previous = state;
    state = value;
    try {
      await core.setSetting(
        key: navBarPositionSettingKey,
        value: value.storageValue,
      );
    } catch (_) {
      state = previous;
      rethrow;
    }
  }

  /// 启动恢复：不回写核心。
  void restore(NavBarPosition value) => state = value;
}

/// 首帧前读取已保存的导航栏位置；缺失或失败时保持默认（底部）。
Future<void> restoreNavBarPosition(ProviderContainer container) async {
  try {
    final raw = await core.getSetting(key: navBarPositionSettingKey);
    if (raw == null) return;
    container
        .read(navBarPositionProvider.notifier)
        .restore(NavBarPosition.fromStorage(raw));
  } catch (_) {}
}
