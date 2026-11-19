// “添加 / 编辑音源”表单背后的纯数据模型：字段校验、默认名称、拼成 SourceConfigDto。
// 这里不碰任何界面代码，也不保存任何密码，方便单测。

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../../rust/api/dto.dart';
import 'strings.dart';

/// 表单里能填的全部字段。不同类型只用其中一部分。
class SourceDraft {
  SourceDraft({
    required this.kind,
    this.name = '',
    this.host = '',
    this.share = '',
    this.path = '',
    this.url = '',
    this.username = '',
    this.secret = '',
    this.guest = false,
  });

  /// 从一条局域网发现结果建一个预填草稿。
  ///
  /// SMB → `smb://host`，WebDAV → `http(s)://host:port/path`。
  /// DLNA 不直接是 Lekis 音源，按「可能有 SMB 共享」预填 SMB 表单。
  factory SourceDraft.fromDiscovered(DiscoveredServiceDto service) {
    switch (service.kind) {
      case DiscoveredKindDto.webDav || DiscoveredKindDto.webDavs:
        return SourceDraft(
          kind: SourceKindDto.webDav,
          name: service.name,
          url: _webDavUrl(service),
        );
      case DiscoveredKindDto.smb || DiscoveredKindDto.mediaServer:
        return SourceDraft(
          kind: SourceKindDto.smb,
          name: service.name,
          // DLNA 的端口是媒体服务器端口，不是 SMB；只借它的主机地址。
          host: service.kind == DiscoveredKindDto.mediaServer
              ? _bracketHost(service.host)
              : _discoveredHost(service, defaultPort: 445),
        );
    }
  }

  /// 从已保存的音源还原表单。**不会**读取凭据明文：密码留在核心的凭据库里，
  /// 界面只用 `credential_ref` 判断“已保存”。
  factory SourceDraft.fromConfig(SourceConfigDto config) {
    final address = config.addresses.isEmpty ? '' : config.addresses.first;
    final optionUser = (config.options['username'] ?? '').trim();
    switch (config.kind) {
      case SourceKindDto.local:
        return SourceDraft(kind: config.kind, name: config.name, path: address);
      case SourceKindDto.smb:
        final uri = Uri.tryParse(address);
        final user = optionUser.isNotEmpty ? optionUser : _userFromUri(uri);
        final segments = uri?.pathSegments ?? const <String>[];
        return SourceDraft(
          kind: config.kind,
          name: config.name,
          host: _uriHost(uri),
          share: segments.isEmpty ? '' : segments.first,
          path: segments.skip(1).join('/'),
          username: user,
          guest: user.isEmpty,
        );
      case SourceKindDto.webDav ||
          SourceKindDto.openSubsonic ||
          SourceKindDto.jellyfin ||
          SourceKindDto.emby ||
          SourceKindDto.plex:
        final uri = Uri.tryParse(address);
        final user = optionUser.isNotEmpty ? optionUser : _userFromUri(uri);
        return SourceDraft(
          kind: config.kind,
          name: config.name,
          url: displayAddress(address),
          username: user,
        );
      default:
        return SourceDraft(kind: config.kind, name: config.name, url: address);
    }
  }

  final SourceKindDto kind;
  String name;

  /// SMB：主机名或 IP（可带端口）。
  String host;

  /// SMB：共享名。
  String share;

  /// 本地：文件夹绝对路径；SMB：共享里的子目录。
  String path;

  /// WebDAV / 媒体服务器：根地址。
  String url;

  String username;

  /// 密码 / API 密钥 / Token。只在内存里停留到交给核心的凭据库为止。
  String secret;

  /// SMB 访客模式（不需要账号）。
  bool guest;

  /// 这个源需不需要凭据。WebDAV 允许匿名，所以用户名是开关。
  bool get usesCredential => switch (kind) {
    SourceKindDto.local => false,
    SourceKindDto.smb => !guest && username.trim().isNotEmpty,
    SourceKindDto.webDav => username.trim().isNotEmpty,
    _ => true,
  };

  /// 清掉内存里的密码。保存成功或页面关闭时调用。
  void forgetSecret() => secret = '';

  /// 转成核心要的配置。密码永远不会出现在 `addresses` 或 `options` 里：
  /// 由调用方先 `setCredential(ref, secret)`，这里只带 `credentialRef`。
  /// 调用前先用 [SourceValidators] 校验过。
  SourceConfigDto toConfig({String? credentialRef, PlatformInt64? id}) {
    final options = <String, String>{};
    final String address;
    switch (kind) {
      case SourceKindDto.local:
        address = path.trim();
      case SourceKindDto.smb:
        address = _smbUrl();
        if (!guest && username.trim().isNotEmpty) {
          options['username'] = username.trim();
        }
      case SourceKindDto.webDav:
        address = normalizeHttpUrl(url);
        if (username.trim().isNotEmpty) {
          options['username'] = username.trim();
        }
      case SourceKindDto.openSubsonic:
        address = normalizeHttpUrl(url);
        if (username.trim().isNotEmpty) {
          options['username'] = username.trim();
        }
      case SourceKindDto.jellyfin || SourceKindDto.emby || SourceKindDto.plex:
        address = normalizeHttpUrl(url);
      default:
        address = url.trim();
    }
    final ref = (credentialRef ?? '').trim();
    return SourceConfigDto(
      id: id,
      kind: kind,
      name: name.trim().isEmpty ? defaultName() : name.trim(),
      addresses: [address],
      rootPath: '',
      credentialRef: ref.isEmpty ? null : ref,
      options: options,
      enabled: true,
    );
  }

  /// 用户没填名称时的默认名：文件夹名 / 共享名 / 主机名。
  String defaultName() {
    switch (kind) {
      case SourceKindDto.local:
        final segments = path
            .split(RegExp(r'[\\/]'))
            .where((s) => s.isNotEmpty)
            .toList();
        return segments.isEmpty ? SourcesStrings.kindLocal : segments.last;
      case SourceKindDto.smb:
        final h = host.trim();
        final s = share.trim();
        return s.isEmpty ? h : '$s @ $h';
      default:
        final parsed = Uri.tryParse(normalizeHttpUrl(url));
        final h = parsed?.host ?? '';
        return h.isEmpty ? kind.name : h;
    }
  }

  static String _webDavUrl(DiscoveredServiceDto service) {
    final scheme = service.kind == DiscoveredKindDto.webDavs ? 'https' : 'http';
    final rawPath = (service.path ?? '').trim();
    final path = rawPath.isEmpty
        ? null
        : (rawPath.startsWith('/') ? rawPath : '/$rawPath');
    return Uri(
      scheme: scheme,
      host: service.host,
      port: service.port > 0 ? service.port : null,
      path: path,
    ).toString();
  }

  static String _discoveredHost(
    DiscoveredServiceDto service, {
    required int defaultPort,
  }) {
    final host = _bracketHost(service.host);
    if (service.port == 0 || service.port == defaultPort) return host;
    return '$host:${service.port}';
  }

  /// IPv6 地址直接拼进 URL 时要加方括号。
  static String _bracketHost(String raw) {
    final host = raw.trim();
    if (host.isEmpty || host.startsWith('[')) return host;
    return host.contains(':') ? '[$host]' : host;
  }

  static String _uriHost(Uri? uri) {
    if (uri == null || uri.host.isEmpty) return '';
    final host = _bracketHost(uri.host);
    return uri.port == 0 ? host : '$host:${uri.port}';
  }

  /// 只取 userinfo 里的用户名；冒号后面的密码一律丢弃。
  static String _userFromUri(Uri? uri) {
    final info = uri?.userInfo ?? '';
    if (info.isEmpty) return '';
    return Uri.decodeComponent(info.split(':').first);
  }

  /// 地址里只有用户名、没有密码。核心会从 `options["username"]` 或这里的
  /// userinfo 取用户名，密码单独按 `credential_ref` 读。
  String _smbUrl() {
    final h = host.trim();
    final s = Uri.encodeComponent(share.trim());
    final sub = path
        .trim()
        .split(RegExp(r'[\\/]'))
        .where((p) => p.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return 'smb://$h/$s${sub.isEmpty ? '' : '/$sub'}';
  }
}

/// 补全协议、去掉结尾斜杠。用户只填 `nas.local:4533` 也能用。
String normalizeHttpUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return value;
  if (!value.contains('://')) value = 'http://$value';
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// 给界面显示用的地址：去掉 userinfo，绝不把密码显示出来。
String displayAddress(String address) {
  final uri = Uri.tryParse(address);
  if (uri == null || uri.userInfo.isEmpty) return address;
  return uri.replace(userInfo: '').toString().replaceFirst('//@', '//');
}

/// 表单校验。返回 `null` 表示通过，否则是给用户看的提示。
abstract final class SourceValidators {
  static String? host(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return SourcesStrings.errHostRequired;
    if (value.contains(RegExp(r'[\s/\\]'))) {
      return SourcesStrings.errHostInvalid;
    }
    return null;
  }

  static String? share(String? v) =>
      (v?.trim() ?? '').isEmpty ? SourcesStrings.errShareRequired : null;

  static String? subPath(String? v) {
    final segments = (v ?? '').split(RegExp(r'[\\/]'));
    return segments.contains('..') ? SourcesStrings.errPathInvalid : null;
  }

  static String? httpUrl(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return SourcesStrings.errUrlRequired;
    final normalized = normalizeHttpUrl(value);
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return SourcesStrings.errUrlInvalid;
    }
    return null;
  }

  static String? username(String? v) =>
      (v?.trim() ?? '').isEmpty ? SourcesStrings.errUsernameRequired : null;

  static String? password(String? v) =>
      (v ?? '').isEmpty ? SourcesStrings.errPasswordRequired : null;

  static String? apiKey(String? v) =>
      (v?.trim() ?? '').isEmpty ? SourcesStrings.errApiKeyRequired : null;

  static String? token(String? v) =>
      (v?.trim() ?? '').isEmpty ? SourcesStrings.errTokenRequired : null;
}
