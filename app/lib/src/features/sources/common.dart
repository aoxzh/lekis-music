// 音源 / 补全 / 设置三个页面共用的小工具：错误文案映射、窗口尺寸判断、页面边距。

import 'package:material_ui/material_ui.dart';

import '../../layout/window_size.dart';
import '../../rust/api/error.dart';
import '../../theme/tokens.dart';
import 'strings.dart';

/// 从任意异常里取出核心错误类别；不是核心错误时返回 `null`。
ErrorKind? coreErrorKind(Object error) =>
    error is CoreError ? error.kind : null;

/// 把核心错误翻译成给用户看的话（绝不显示 `detail`）。
String describeCoreError(Object error) {
  final kind = coreErrorKind(error);
  if (kind == null) return SourcesStrings.errUnknown;
  return switch (kind) {
    ErrorKind.notFound => SourcesStrings.errNotFound,
    ErrorKind.invalidArgument => SourcesStrings.errInvalidArgument,
    ErrorKind.unsupported => SourcesStrings.errUnsupported,
    ErrorKind.notImplemented => SourcesStrings.errNotImplemented,
    ErrorKind.io => SourcesStrings.errIo,
    ErrorKind.network => SourcesStrings.errNetwork,
    ErrorKind.auth => SourcesStrings.errAuth,
    ErrorKind.database => SourcesStrings.errDatabase,
    ErrorKind.decode => SourcesStrings.errDecode,
    ErrorKind.plugin => SourcesStrings.errPlugin,
    ErrorKind.permissionDenied => SourcesStrings.errPermissionDenied,
    ErrorKind.cancelled => SourcesStrings.errCancelled,
    ErrorKind.rateLimited => SourcesStrings.errRateLimited,
    ErrorKind.internal => SourcesStrings.errInternal,
  };
}

extension FeatureLayoutX on BuildContext {
  /// 手机竖屏级别的窄窗口（按窗口尺寸，不按设备类型）。
  bool get isCompactWidth => widthClass == WindowWidthClass.compact;

  /// 页面左右留白：窄窗口用移动端边距，其余用桌面边距。
  double get featureGutter =>
      isCompactWidth ? LekisSpacing.pageGutter : LekisSpacing.pageGutterDesktop;
}

/// 显示一条简短提示。
void showFeatureSnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// 页面内容的最大宽度：超宽窗口里不让表单和列表拉得太长。
const double featureMaxContentWidth = LekisSizes.desktopSidebarWidth * 3;
