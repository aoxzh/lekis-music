import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_video_window.dart';
import 'external_url.dart';

const _channel = MethodChannel('dev.lekis/video');

enum VideoOpenResult { inApp, external }

/// Opens an official video page supplied by a source plugin.
///
/// macOS uses the existing sandboxed WKWebView window, Android its WebView
/// activity, and Windows / Linux the WebView2 / WebKitGTK window. If an in-app
/// runtime is missing, the page goes to the system browser instead.
Future<VideoOpenResult> openVideoPage({
  required String url,
  String? title,
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw ArgumentError.value(url, 'url', 'Expected an HTTPS page URL');
  }
  final target = uri.toString();
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    await _channel.invokeMethod<void>('open', {
      'url': target,
      if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
    });
    return VideoOpenResult.inApp;
  }
  if (await openDesktopVideoWindow(url: target, title: title)) {
    return VideoOpenResult.inApp;
  }
  if (!await openExternalUrl(target)) {
    throw StateError('Could not open the video page');
  }
  return VideoOpenResult.external;
}
