// “添加 / 编辑音源”表单背后的纯数据模型：字段校验、默认名称、拼成 SourceConfigDto。
// 这里不碰任何界面代码，也不保存任何密码，方便单测。

import 'dart:convert';

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
    this.port = '',
    this.useKey = false,
    this.keyPassphrase = '',
    this.alternateAddresses = const [],
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
          alternateAddresses: config.addresses.skip(1).toList(growable: false),
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
          alternateAddresses: config.addresses.skip(1).toList(growable: false),
        );
      case SourceKindDto.nfs:
        final uri = Uri.tryParse(address);
        final subdir = uri?.queryParameters['subdir'] ?? '';
        return SourceDraft(
          kind: config.kind,
          name: config.name,
          host: _uriHost(uri),
          share: uri == null ? '' : Uri.decodeComponent(uri.path),
          path: subdir,
          alternateAddresses: config.addresses.skip(1).toList(growable: false),
        );
      case SourceKindDto.sftp:
        final uri = Uri.tryParse(address);
        final user = optionUser.isNotEmpty ? optionUser : _userFromUri(uri);
        return SourceDraft(
          kind: config.kind,
          name: config.name,
          host: uri == null || uri.host.isEmpty ? '' : _bracketHost(uri.host),
          port: uri != null && uri.hasPort && uri.port != _sftpDefaultPort
              ? '${uri.port}'
              : '',
          path: (uri?.pathSegments ?? const <String>[])
              .where((s) => s.isNotEmpty)
              .join('/'),
          username: user,
          useKey: (config.options[sftpAuthOption] ?? '') == sftpAuthKey,
          alternateAddresses: config.addresses.skip(1).toList(growable: false),
        );
      default:
        return SourceDraft(
          kind: config.kind,
          name: config.name,
          url: address,
          alternateAddresses: config.addresses.skip(1).toList(growable: false),
        );
    }
  }

  /// SFTP 默认端口。
  static const _sftpDefaultPort = 22;

  /// 源配置 `options` 里 SFTP 认证方式的键 / 私钥登录的取值（和核心 `lekis-vfs` 一致）。
  static const sftpAuthOption = 'auth';
  static const sftpAuthKey = 'key';

  final SourceKindDto kind;
  String name;

  /// SMB / NFS / SFTP：主机名或 IP（SMB、NFS 可带端口）。
  String host;

  /// SMB：共享名；NFS：导出路径（如 `/volume1/music`）。
  String share;

  /// 本地：文件夹绝对路径；SMB / NFS：共享里的子目录；SFTP：服务器上的目录。
  String path;

  /// WebDAV / 媒体服务器：根地址。
  String url;

  String username;

  /// 密码 / API 密钥 / Token。只在内存里停留到交给核心的凭据库为止。
  String secret;

  /// SMB 访客模式（不需要账号）。
  bool guest;

  /// SFTP：SSH 端口，留空用 22。
  String port;

  /// SFTP：用私钥登录（[secret] 是私钥文本）而不是密码。
  bool useKey;

  /// SFTP 私钥的 passphrase（可选）。和私钥一起存进凭据库，同样不进配置。
  String keyPassphrase;

  /// 备用地址（家里 NAS / Tailscale / 外网）。按顺序尝试，失败自动切下一个。
  final List<String> alternateAddresses;

  /// 本地文件夹只有一个路径，其他音源可以配置备用地址。
  bool get supportsAlternateAddresses => kind != SourceKindDto.local;

  /// 这个源需不需要凭据。WebDAV 允许匿名，所以用户名是开关。
  bool get usesCredential => switch (kind) {
    SourceKindDto.local || SourceKindDto.nfs => false,
    SourceKindDto.smb => !guest && username.trim().isNotEmpty,
    SourceKindDto.webDav => username.trim().isNotEmpty,
    _ => true,
  };

  /// 真正写进凭据库的内容。SFTP 私钥登录时是
  /// `{"private_key": ..., "passphrase": ...}`，核心按 `options["auth"]` 解析；
  /// 其他情况就是密码 / 密钥本身。没有输入时返回空串。
  String get credentialSecret {
    if (kind == SourceKindDto.sftp && useKey) {
      final key = secret.trim();
      if (key.isEmpty) return '';
      return jsonEncode({
        'private_key': key,
        if (keyPassphrase.isNotEmpty) 'passphrase': keyPassphrase,
      });
    }
    return secret;
  }

  /// 清掉内存里的密码。保存成功或页面关闭时调用。
  void forgetSecret() {
    secret = '';
    keyPassphrase = '';
  }

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
      case SourceKindDto.nfs:
        address = _nfsUrl();
      case SourceKindDto.sftp:
        address = _sftpUrl();
        if (username.trim().isNotEmpty) {
          options['username'] = username.trim();
        }
        if (useKey) options[sftpAuthOption] = sftpAuthKey;
      default:
        address = url.trim();
    }
    final ref = (credentialRef ?? '').trim();
    final addresses = <String>[address];
    for (final raw in alternateAddresses) {
      final extra = _normalizeAlternate(raw);
      if (extra.isNotEmpty && extra != address && !addresses.contains(extra)) {
        addresses.add(extra);
      }
    }
    return SourceConfigDto(
      id: id,
      kind: kind,
      name: name.trim().isEmpty ? defaultName() : name.trim(),
      addresses: addresses,
      rootPath: '',
      credentialRef: ref.isEmpty ? null : ref,
      options: options,
      enabled: true,
    );
  }

  String _normalizeAlternate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return value;
    return switch (kind) {
      SourceKindDto.webDav ||
      SourceKindDto.openSubsonic ||
      SourceKindDto.jellyfin ||
      SourceKindDto.emby ||
      SourceKindDto.plex => normalizeHttpUrl(value),
      SourceKindDto.smb => value.contains('://') ? value : 'smb://$value',
      SourceKindDto.nfs => value.contains('://') ? value : 'nfs://$value',
      SourceKindDto.sftp => value.contains('://') ? value : 'sftp://$value',
      _ => value,
    };
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
      case SourceKindDto.nfs || SourceKindDto.sftp:
        final h = host.trim();
        final last = _segments(
          kind == SourceKindDto.nfs && path.trim().isEmpty ? share : path,
        );
        return last.isEmpty ? h : '${last.last} @ $h';
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

  static List<String> _segments(String raw) =>
      raw.trim().split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();

  static String _encodedPath(String raw) =>
      _segments(raw).map(Uri.encodeComponent).join('/');

  /// `nfs://host[:portmapper]/export[?subdir=a/b]`。子目录不是独立的导出，
  /// 核心先挂导出根再逐级查找。
  String _nfsUrl() {
    final h = host.trim();
    final export = _encodedPath(share);
    final sub = _segments(path).join('/');
    final query = sub.isEmpty
        ? ''
        : '?subdir=${Uri.encodeQueryComponent(sub)}';
    return 'nfs://$h/$export$query';
  }

  /// `sftp://host[:port]/path`。用户名放 options，密码 / 私钥按引用存。
  String _sftpUrl() {
    final h = host.trim();
    final p = port.trim();
    final sub = _encodedPath(path);
    return 'sftp://$h${p.isEmpty ? '' : ':$p'}/$sub';
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

  static String? nfsExport(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty || value == '/') return SourcesStrings.errExportRequired;
    return subPath(value);
  }

  /// 可选端口：留空通过，否则必须是 1~65535。
  static String? port(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return null;
    final n = int.tryParse(value);
    return n == null || n < 1 || n > 65535 ? SourcesStrings.errPortInvalid : null;
  }

  static String? privateKey(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return SourcesStrings.errPrivateKeyRequired;
    return value.contains('PRIVATE KEY') ? null : SourcesStrings.errPrivateKeyInvalid;
  }

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
