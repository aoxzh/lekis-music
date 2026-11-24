import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// In-app video window for Windows and Linux.
///
/// macOS keeps its existing WKWebView window and Android its WebView activity;
/// this file only fills the desktop gap with WebView2 / WebKitGTK. When the
/// runtime is missing or window creation fails, callers fall back to the
/// system browser.
Webview? _window;
String? _allowedHost;

bool get supportsDesktopVideoWindow =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

Future<bool> openDesktopVideoWindow({
  required String url,
  String? title,
}) async {
  if (!supportsDesktopVideoWindow) return false;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;

  try {
    if (!await WebviewWindow.isWebviewAvailable()) return false;

    final existing = _window;
    if (existing != null) {
      try {
        _allowedHost = uri.host;
        await existing.launch(url, triggerOnUrlRequestEvent: false);
        return true;
      } catch (_) {
        _window = null;
      }
    }

    final support = await getApplicationSupportDirectory();
    final profile = Directory(
      '${support.path}${Platform.pathSeparator}WebView2',
    );
    await profile.create(recursive: true);

    final webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        title: (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : 'Lekis · 视频',
        windowWidth: 960,
        windowHeight: 600,
        titleBar: const TitleBarOptions(
          showNavigation: true,
          showReload: true,
          showTitle: true,
          showHost: true,
        ),
        windows: WindowsWebviewOptions(userDataFolder: profile.path),
      ),
    );
    _window = webview;
    _allowedHost = uri.host;
    unawaited(
      webview.onClose.then((_) {
        if (identical(_window, webview)) _window = null;
      }),
    );
    await webview.setOnUrlRequestCallback((target) {
      final next = Uri.tryParse(target);
      return next != null &&
          next.scheme == 'https' &&
          next.host == _allowedHost;
    });
    await webview.launch(url, triggerOnUrlRequestEvent: false);
    return true;
  } catch (error, stack) {
    debugPrint('desktop video window unavailable: $error\n$stack');
    _window = null;
    return false;
  }
}
