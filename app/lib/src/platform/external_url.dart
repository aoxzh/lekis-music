import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _androidChannel = MethodChannel('dev.lekis.lekis/discovery');

/// Opens an external `http` or `https` URL in the system browser.
///
/// Returns `true` when the OS accepted the launch request.
Future<bool> openExternalUrl(String rawUrl) async {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return false;
  }
  final url = uri.toString();
  try {
    if (Platform.isAndroid) {
      final ok = await _androidChannel.invokeMethod<bool>('openUrl', {
        'url': url,
      });
      return ok ?? false;
    }
    if (Platform.isWindows) {
      final result = await Process.run('rundll32', [
        'url.dll,FileProtocolHandler',
        url,
      ]);
      return result.exitCode == 0;
    }
    if (Platform.isMacOS) {
      final result = await Process.run('open', [url]);
      return result.exitCode == 0;
    }
    if (Platform.isLinux) {
      final result = await Process.run('xdg-open', [url]);
      return result.exitCode == 0;
    }
  } catch (_) {
    return false;
  }
  return false;
}
