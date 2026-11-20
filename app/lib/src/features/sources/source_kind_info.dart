// 音源类型的图标与名称。

import 'package:material_ui/material_ui.dart';

import '../../rust/api/dto.dart';
import 'strings.dart';

extension SourceKindInfo on SourceKindDto {
  String get label => switch (this) {
    SourceKindDto.local => SourcesStrings.kindLocal,
    SourceKindDto.smb => SourcesStrings.kindSmb,
    SourceKindDto.webDav => SourcesStrings.kindWebDav,
    SourceKindDto.nfs => SourcesStrings.kindNfs,
    SourceKindDto.sftp => SourcesStrings.kindSftp,
    SourceKindDto.openSubsonic => SourcesStrings.kindOpenSubsonic,
    SourceKindDto.jellyfin => SourcesStrings.kindJellyfin,
    SourceKindDto.emby => SourcesStrings.kindEmby,
    SourceKindDto.plex => SourcesStrings.kindPlex,
    SourceKindDto.radio => SourcesStrings.kindRadio,
    SourceKindDto.plugin => SourcesStrings.kindPlugin,
  };

  String? get hint => switch (this) {
    SourceKindDto.local => SourcesStrings.kindLocalHint,
    SourceKindDto.smb => SourcesStrings.kindSmbHint,
    SourceKindDto.webDav => SourcesStrings.kindWebDavHint,
    SourceKindDto.nfs => SourcesStrings.kindNfsHint,
    SourceKindDto.sftp => SourcesStrings.kindSftpHint,
    SourceKindDto.openSubsonic => SourcesStrings.kindOpenSubsonicHint,
    SourceKindDto.jellyfin => SourcesStrings.kindJellyfinHint,
    SourceKindDto.plex => SourcesStrings.kindPlexHint,
    _ => null,
  };

  IconData get icon => switch (this) {
    SourceKindDto.local => Icons.folder_outlined,
    SourceKindDto.smb => Icons.lan_outlined,
    SourceKindDto.nfs => Icons.storage_outlined,
    SourceKindDto.webDav => Icons.cloud_outlined,
    SourceKindDto.sftp => Icons.terminal,
    SourceKindDto.openSubsonic ||
    SourceKindDto.jellyfin ||
    SourceKindDto.emby ||
    SourceKindDto.plex => Icons.dns_outlined,
    SourceKindDto.radio => Icons.radio_outlined,
    SourceKindDto.plugin => Icons.extension_outlined,
  };

  /// 通过网络访问的音源（NAS 共享、媒体服务器）。只有它们才有“测试连接”、
  /// 账号凭据和备用地址；本地文件夹、电台和插件都没有这些。
  bool get isNetwork => switch (this) {
    SourceKindDto.smb ||
    SourceKindDto.webDav ||
    SourceKindDto.nfs ||
    SourceKindDto.sftp ||
    SourceKindDto.openSubsonic ||
    SourceKindDto.jellyfin ||
    SourceKindDto.emby ||
    SourceKindDto.plex => true,
    SourceKindDto.local || SourceKindDto.radio || SourceKindDto.plugin => false,
  };

  /// 文件系统类音源（可以同步、走 VFS 扫描）。
  bool get isFilesystem => switch (this) {
    SourceKindDto.local ||
    SourceKindDto.smb ||
    SourceKindDto.webDav ||
    SourceKindDto.nfs ||
    SourceKindDto.sftp => true,
    _ => false,
  };
}
