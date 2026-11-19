// 发现结果在界面上的类型名称、图标和地址展示。

import 'package:material_ui/material_ui.dart';

import '../../rust/api/dto.dart';
import 'strings.dart';

extension DiscoveredServiceInfo on DiscoveredServiceDto {
  /// 点这条结果后打开哪种音源表单。DLNA 按「可能有 SMB 共享」处理。
  SourceKindDto get targetKind => switch (kind) {
    DiscoveredKindDto.webDav ||
    DiscoveredKindDto.webDavs => SourceKindDto.webDav,
    DiscoveredKindDto.smb || DiscoveredKindDto.mediaServer => SourceKindDto.smb,
  };

  String get kindLabel => switch (kind) {
    DiscoveredKindDto.smb => SourcesStrings.kindSmb,
    DiscoveredKindDto.webDav ||
    DiscoveredKindDto.webDavs => SourcesStrings.kindWebDav,
    DiscoveredKindDto.mediaServer => SourcesStrings.kindDlna,
  };

  IconData get icon => switch (kind) {
    DiscoveredKindDto.smb => Icons.lan_outlined,
    DiscoveredKindDto.webDav ||
    DiscoveredKindDto.webDavs => Icons.cloud_outlined,
    DiscoveredKindDto.mediaServer => Icons.cast_outlined,
  };

  String get viaLabel => switch (via) {
    DiscoveryProtocolDto.mdns => SourcesStrings.viaMdns,
    DiscoveryProtocolDto.wsDiscovery => SourcesStrings.viaWsDiscovery,
    DiscoveryProtocolDto.ssdp => SourcesStrings.viaSsdp,
  };

  /// 展示给用户看的连接地址：`host:port`，WebDAV 带上路径。
  String get addressLine {
    final hostPart = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    final port = this.port > 0 ? ':${this.port}' : '';
    final path = (this.path ?? '').trim();
    final suffix = path.isEmpty ? '' : (path.startsWith('/') ? path : '/$path');
    return '$hostPart$port$suffix';
  }

  /// DLNA 不是 Lekis 音源，只作为「可能提供 SMB 共享」的提示。
  String? get note => kind == DiscoveredKindDto.mediaServer
      ? SourcesStrings.discoveryDlnaNote
      : null;
}
