// “添加音源”表单背后的纯数据模型：字段校验、默认名称、拼成 SourceConfigDto。
// 这里不碰任何界面代码，方便单测。

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

  /// 密码 / API 密钥 / Token。只在内存里停留到交给核心为止。
  String secret;

  /// SMB 访客模式（不需要账号）。
  bool guest;

  /// 清掉内存里的密码。保存成功或页面关闭时调用。
  void forgetSecret() => secret = '';

  /// 转成核心要的配置。调用前先用 [SourceValidators] 校验过。
  SourceConfigDto toConfig() {
    final options = <String, String>{};
    final String address;
    switch (kind) {
      case SourceKindDto.local:
        address = path.trim();
      case SourceKindDto.smb:
        address = _smbUrl();
      case SourceKindDto.webDav:
        address = _withUserInfo(normalizeHttpUrl(url), username.trim(), secret);
      case SourceKindDto.openSubsonic:
        address = normalizeHttpUrl(url);
        options['username'] = username.trim();
        _handOffServerSecret(options, 'token');
      case SourceKindDto.jellyfin || SourceKindDto.emby:
        address = normalizeHttpUrl(url);
        _handOffServerSecret(options, 'api_key');
      case SourceKindDto.plex:
        address = normalizeHttpUrl(url);
        _handOffServerSecret(options, 'token');
      default:
        address = url.trim();
    }
    return SourceConfigDto(
      kind: kind,
      name: name.trim().isEmpty ? defaultName() : name.trim(),
      addresses: [address],
      rootPath: '',
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

  String _smbUrl() {
    final h = host.trim();
    final s = Uri.encodeComponent(share.trim());
    final sub = path
        .trim()
        .split(RegExp(r'[\\/]'))
        .where((p) => p.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final base = 'smb://$h/$s${sub.isEmpty ? '' : '/$sub'}';
    if (guest) return base;
    return _withUserInfo(base, username.trim(), secret);
  }

  // TODO(core-credentials): 核心还没有把凭据写进 CredentialStore 的桥接函数
  // （SourceConfigDto 只有 credentialRef，没有地方传密码本身）。在那之前，按核心
  // 文档里约定的兜底方式把密钥交给核心：SMB / WebDAV 放进地址的 userinfo（核心
  // 解析时会剥掉，不进日志），媒体服务器放进 options。两种方式都会被核心写进
  // 资料库，所以一旦有了 `set_credential(ref, secret)`，这里改成先存凭据、再只传
  // credentialRef。Dart 侧不保存任何密码。
  void _handOffServerSecret(Map<String, String> options, String key) {
    if (secret.isNotEmpty) options[key] = secret;
  }

  static String _withUserInfo(String url, String user, String password) {
    if (user.isEmpty) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final info = password.isEmpty
        ? Uri.encodeComponent(user)
        : '${Uri.encodeComponent(user)}:${Uri.encodeComponent(password)}';
    return uri.replace(userInfo: info).toString();
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
