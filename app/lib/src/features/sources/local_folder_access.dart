// 选择本地音乐文件夹，以及 Android 上的存储权限说明。

import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'strings.dart';

sealed class FolderPickResult {
  const FolderPickResult();
}

final class FolderPicked extends FolderPickResult {
  const FolderPicked(this.path);
  final String path;
}

final class FolderPickCancelled extends FolderPickResult {
  const FolderPickCancelled();
}

/// 选择失败或选到了核心读不了的位置；[message] 直接给用户看。
final class FolderPickFailed extends FolderPickResult {
  const FolderPickFailed(this.message);
  final String message;
}

/// 打开系统文件夹选择器。
Future<FolderPickResult> pickMusicFolder() async {
  if (Platform.isAndroid && !await ensureAudioPermission()) {
    return FolderPickFailed(SourcesStrings.audioPermissionDenied);
  }
  try {
    // 核心的 LocalVfs 只认文件系统路径，所以这里仍用 getDirectoryPath 而不是
    // 返回 content:// Uri 的 pickDirectory()。核心支持 SAF 之后再换。
    // ignore: deprecated_member_use
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: SourcesStrings.pickFolder,
    );
    if (path == null || path.isEmpty) return const FolderPickCancelled();
    // 核心的本地音源按普通文件路径读；SAF 的 content:// 树还不支持。
    if (path.startsWith('content://')) {
      return FolderPickFailed(SourcesStrings.androidContentUri);
    }
    return FolderPicked(path);
  } catch (_) {
    return FolderPickFailed(SourcesStrings.folderPickFailed);
  }
}

/// Android 上读本地音乐需要“音乐和音频”（READ_MEDIA_AUDIO / 旧版 READ_EXTERNAL_STORAGE）权限。
///
bool get localFolderNeedsPermissionNotice => Platform.isAndroid;

/// 请求读本地音乐的权限（Android 13+ 是 READ_MEDIA_AUDIO，旧版本是存储权限）。
/// 被永久拒绝时打开系统设置。返回是否已获得权限。
Future<bool> ensureAudioPermission() async {
  if (!Platform.isAndroid) return true;
  var status = await Permission.audio.request();
  if (!status.isGranted) {
    status = await Permission.storage.request();
  }
  if (status.isPermanentlyDenied) {
    await openAppSettings();
  }
  // 可选：文件夹里的 cover.jpg 是图片，需要“照片和视频”权限才能直接读取。
  // 用户拒绝也不影响扫描和播放，内嵌封面仍可用。
  if (status.isGranted || status.isLimited) {
    await Permission.photos.request();
  }
  return status.isGranted || status.isLimited;
}
