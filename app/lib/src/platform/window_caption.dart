// Keeps the native window caption (title bar) in the app's brightness.
//
// The Windows runner otherwise follows the system "app mode", so a dark
// Lekis window on a light Windows desktop gets a white strip on top. The
// runner listens on `lekis/window` (see windows/runner/flutter_window.cpp).

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Tells the Windows runner to paint its caption light or dark to match
/// the theme above this widget. A no-op on other platforms.
class WindowCaptionSync extends StatefulWidget {
  const WindowCaptionSync({super.key, required this.child});

  final Widget child;

  static const MethodChannel _channel = MethodChannel('lekis/window');

  @override
  State<WindowCaptionSync> createState() => _WindowCaptionSyncState();
}

class _WindowCaptionSyncState extends State<WindowCaptionSync> {
  Brightness? _sent;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    final brightness = Theme.of(context).brightness;
    if (brightness == _sent) return;
    _sent = brightness;
    WindowCaptionSync._channel
        .invokeMethod<void>('setDarkCaption', brightness == Brightness.dark)
        // Older runners (or tests) have no handler; the caption then just
        // keeps following Windows.
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
