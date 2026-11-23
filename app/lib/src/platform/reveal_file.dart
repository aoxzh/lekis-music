import 'dart:io';

/// Whether the current platform has a file manager we can reveal files in.
bool get canRevealFiles => !Platform.isAndroid && !Platform.isIOS;

/// Reveals [path] in the system file manager. Returns false when the
/// platform has no supported reveal action or the process could not start.
Future<bool> revealFile(String path) async {
  if (path.isEmpty || !canRevealFiles) return false;
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [
        '/select,',
        path,
      ], mode: ProcessStartMode.detached);
      return true;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [
        '-R',
        path,
      ], mode: ProcessStartMode.detached);
      return true;
    }
    if (Platform.isLinux) {
      final dir = File(path).parent.path;
      await Process.start('xdg-open', [
        dir.isEmpty ? path : dir,
      ], mode: ProcessStartMode.detached);
      return true;
    }
  } catch (_) {
    return false;
  }
  return false;
}
