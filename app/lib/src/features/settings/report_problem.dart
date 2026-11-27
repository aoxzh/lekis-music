// "Report a Problem": the diagnostics bundle and the prefilled GitHub issue.
//
// Nothing here leaves the device on its own. The bundle is a zip the user
// saves or shares themselves, and the issue URL only carries the environment
// summary below, which never holds library paths, user names, host names,
// addresses, credentials or (unless the user opts in) the device ID.
// Everything that does come from logs goes through [redactDiagnostics].

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../rust/api/dto.dart';
import 'app_updater.dart';

/// The project repository (About, issues, releases).
const String kLekisRepoUrl = 'https://github.com/aoxzh/lekis-music';

/// GitHub's issue page.
const String kLekisIssuesUrl = '$kLekisRepoUrl/issues';

/// Upper bound for the prefilled new-issue URL. Browsers and GitHub cope
/// with more, but `rundll32` / Android intents and some proxies do not.
const int kIssueUrlMaxLength = 6000;

/// Title the issue opens with; matches `.github/ISSUE_TEMPLATE/bug_report.md`.
const String kIssueTitlePlaceholder = '[Bug]: ';

// ---------------------------------------------------------------------------
// Environment summary
// ---------------------------------------------------------------------------

/// The non-sensitive facts a bug report needs.
@immutable
class DiagnosticsEnvironment {
  const DiagnosticsEnvironment({
    required this.appVersion,
    required this.buildMode,
    required this.os,
    required this.osVersion,
    required this.arch,
    required this.uiProfile,
    required this.systemLocale,
    required this.appLanguage,
    this.coreVersion,
    this.deviceModel,
    this.windowClass,
    this.outputMode,
    this.sourceKinds = const {},
    this.deviceId,
  });

  final String appVersion;
  final String buildMode;
  final String? coreVersion;
  final String os;
  final String osVersion;
  final String arch;
  final String? deviceModel;
  final String uiProfile;
  final String? windowClass;
  final String systemLocale;
  final String appLanguage;
  final String? outputMode;

  /// Source kind → how many are configured. Kinds only: no names, no paths.
  final Map<String, int> sourceKinds;

  /// Only set when the user ticked "include device ID".
  final String? deviceId;

  DiagnosticsEnvironment withDeviceId(String? id) => DiagnosticsEnvironment(
    appVersion: appVersion,
    buildMode: buildMode,
    coreVersion: coreVersion,
    os: os,
    osVersion: osVersion,
    arch: arch,
    deviceModel: deviceModel,
    uiProfile: uiProfile,
    windowClass: windowClass,
    systemLocale: systemLocale,
    appLanguage: appLanguage,
    outputMode: outputMode,
    sourceKinds: sourceKinds,
    deviceId: id,
  );

  /// Label / value pairs, most useful first (the issue URL drops from the
  /// end when it runs out of room).
  List<(String, String)> get rows {
    String or(String? v) => (v == null || v.trim().isEmpty) ? '-' : v.trim();
    final sources = sourceKinds.isEmpty
        ? '-'
        : (sourceKinds.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
              .map((e) => '${e.key} x${e.value}')
              .join(', ');
    return [
      ('App Version', '$appVersion ($buildMode)'),
      ('Core Version', or(coreVersion)),
      ('OS', '$os ${or(osVersion)}'),
      ('Arch', arch),
      ('Device Model', or(deviceModel)),
      ('UI Profile', [uiProfile, ?windowClass].join(' / ')),
      ('Locale', '$systemLocale (app: $appLanguage)'),
      ('Output Mode', or(outputMode)),
      ('Sources', sources),
      if (deviceId != null && deviceId!.isNotEmpty) ('Device ID', deviceId!),
    ];
  }

  /// `Label: value` lines (preview, clipboard, `environment.txt`).
  String toPlainText() => rows.map((r) => '${r.$1}: ${r.$2}').join('\n');

  /// Markdown bullet list for the issue body.
  String toMarkdown([int? maxRows]) {
    final list = rows;
    final n = maxRows == null ? list.length : maxRows.clamp(0, list.length);
    return list.take(n).map((r) => '- **${r.$1}**: ${r.$2}').join('\n');
  }

  Map<String, Object?> toJson() => {
    'appVersion': appVersion,
    'buildMode': buildMode,
    'coreVersion': coreVersion,
    'os': os,
    'osVersion': osVersion,
    'arch': arch,
    'deviceModel': deviceModel,
    'uiProfile': uiProfile,
    'windowClass': windowClass,
    'systemLocale': systemLocale,
    'appLanguage': appLanguage,
    'outputMode': outputMode,
    'sourceKinds': sourceKinds,
    if (deviceId != null) 'deviceId': deviceId,
  };
}

const MethodChannel _androidChannel = MethodChannel('dev.lekis.lekis/discovery');

/// Reads the environment of the running app. Every probe is best-effort:
/// a failure leaves that field empty instead of failing the report.
Future<DiagnosticsEnvironment> collectDiagnosticsEnvironment({
  required String? coreVersion,
  required String uiProfile,
  required String appLanguage,
  String? windowClass,
  OutputModeDto? outputMode,
  List<SourceConfigDto> sources = const [],
}) async {
  final kinds = <String, int>{};
  for (final s in sources) {
    kinds.update(s.kind.name, (n) => n + 1, ifAbsent: () => 1);
  }
  var os = Platform.operatingSystem;
  var osVersion = Platform.operatingSystemVersion;
  String? model;
  if (Platform.isAndroid) {
    try {
      final info = await _androidChannel
          .invokeMapMethod<String, Object?>('deviceModel')
          .timeout(const Duration(seconds: 2));
      if (info != null) {
        final maker = '${info['manufacturer'] ?? ''}'.trim();
        final m = '${info['model'] ?? ''}'.trim();
        model = m.toLowerCase().startsWith(maker.toLowerCase())
            ? m
            : '$maker $m'.trim();
        final release = '${info['release'] ?? ''}'.trim();
        final sdk = info['sdk'];
        if (release.isNotEmpty) {
          os = 'Android';
          osVersion = sdk == null ? release : '$release (SDK $sdk)';
        }
      }
    } on Object {
      // Channel missing (tests, older builds): keep the kernel string.
    }
  } else {
    model = await _desktopModel();
  }
  return DiagnosticsEnvironment(
    appVersion: kLekisAppVersion,
    buildMode: kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
    coreVersion: coreVersion,
    os: os,
    // The OS string comes from the platform; scrub it like any other text.
    osVersion: redactDiagnostics(osVersion.replaceAll('"', '').trim()),
    arch: _arch(),
    deviceModel: model == null || model.isEmpty
        ? null
        : redactDiagnostics(model),
    uiProfile: uiProfile,
    windowClass: windowClass,
    systemLocale: Platform.localeName,
    appLanguage: appLanguage,
    outputMode: outputMode?.name,
    sourceKinds: kinds,
  );
}

String _arch() {
  try {
    return Abi.current().toString();
  } on Object {
    return '-';
  }
}

/// Hardware model on desktop (e.g. "ThinkPad X1 Carbon"), not the hostname.
Future<String?> _desktopModel() async {
  try {
    if (Platform.isWindows) {
      final r = await Process.run('reg', [
        'query',
        r'HKLM\HARDWARE\DESCRIPTION\System\BIOS',
        '/v',
        'SystemProductName',
      ]).timeout(const Duration(seconds: 2));
      final m = RegExp(
        r'SystemProductName\s+REG_SZ\s+(.+)',
      ).firstMatch('${r.stdout}');
      return m?.group(1)?.trim();
    }
    if (Platform.isMacOS) {
      final r = await Process.run('sysctl', [
        '-n',
        'hw.model',
      ]).timeout(const Duration(seconds: 2));
      return '${r.stdout}'.trim();
    }
    if (Platform.isLinux) {
      final f = File('/sys/devices/virtual/dmi/id/product_name');
      if (await f.exists()) return (await f.readAsString()).trim();
    }
  } on Object {
    // Unknown model is fine.
  }
  return null;
}

// ---------------------------------------------------------------------------
// Redaction
// ---------------------------------------------------------------------------

/// Device-specific strings to scrub on top of the generic patterns: the
/// user's home folder, account name, host / Connect device name and the
/// device ID (when the user did not opt in to sharing it).
@immutable
class RedactionContext {
  const RedactionContext({this.literals = const []});

  /// `(text, placeholder)` pairs, replaced case-insensitively.
  final List<(String, String)> literals;

  /// The values of the running device.
  static Future<RedactionContext> current({
    String? hiddenDeviceId,
    String? deviceName,
  }) async {
    final env = Platform.environment;
    final out = <(String, String)>[];
    void add(String? v, String label, {int min = 3}) {
      final t = v?.trim() ?? '';
      if (t.length >= min) out.add((t, label));
    }

    for (final key in const ['USERPROFILE', 'HOME']) {
      final home = env[key];
      // `/` or `C:\` alone would wreck every path.
      if (home != null && home.length > 3) {
        add(home, '<home>');
        add(home.replaceAll(r'\', '/'), '<home>');
        add(home.replaceAll(r'\', r'\\'), '<home>');
      }
    }
    add(env['USERNAME'], '<user>');
    add(env['USER'], '<user>');
    try {
      final host = Platform.localHostname;
      if (host.toLowerCase() != 'localhost') add(host, '<host>');
    } on Object {
      // Sandboxed: nothing to scrub.
    }
    add(deviceName, '<device-name>');
    add(hiddenDeviceId, '<device-id>', min: 6);
    return RedactionContext(literals: out);
  }
}

/// Hosts whose name is useful in a report and says nothing about the user.
const _publicHostSuffixes = [
  'github.com',
  'githubusercontent.com',
  'musicbrainz.org',
  'coverartarchive.org',
  'lrclib.net',
  'last.fm',
  'audioscrobbler.com',
  'listenbrainz.org',
  'spotify.com',
  'scdn.co',
  'apple.com',
  'mzstatic.com',
  'deezer.com',
  'qq.com',
  'gtimg.cn',
  '163.com',
  '126.net',
  'kugou.com',
  'kuwo.cn',
  'bilibili.com',
  'radio-browser.info',
];

final _authHeader = RegExp(
  r'\b(Bearer|Basic|Digest|Token)\s+[A-Za-z0-9._~+/=:-]{6,}',
  caseSensitive: false,
);
final _jwt = RegExp(r'\beyJ[\w-]{4,}\.[\w-]{4,}\.[\w-]{4,}');
final _url = RegExp(r'''\b([a-zA-Z][a-zA-Z0-9+.\-]{1,15})://([^\s"'<>`]+)''');
final _unc = RegExp(r'''(^|[\s"'(=\[])\\\\([^\\/\s"']+)\\''', multiLine: true);
final _winHome = RegExp(
  r'''([A-Za-z]:(?:\\\\|\\|/)+(?:Users|Documents and Settings)(?:\\\\|\\|/)+)([^\\/\s"':*?<>|]+)''',
  caseSensitive: false,
);
final _unixHome = RegExp(r'''(/(?:home|Users)/)([^/\s"'<>]+)''');
final _mac = RegExp(
  r'(?<![0-9A-Za-z_:\-])(?:[0-9A-Fa-f]{2}([:\-]))(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}(?![0-9A-Za-z_:\-])',
);
final _ipv4 = RegExp(
  r'(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d]|\.\d)',
);
final _ipv6Full = RegExp(
  r'(?<![0-9A-Za-z_:.])(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}(?![0-9A-Za-z_:])',
);
final _ipv6Short = RegExp(
  r'(?<![0-9A-Za-z_:.])(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?(?![0-9A-Za-z_:])',
);
final _email = RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}');
final _secretKv = RegExp(
  r'''\b(password|passwd|passphrase|pwd|pass|token|access_token|refresh_token|id_token|auth_token|api[_\-]?key|apikey|secret|client_secret|authorization|cookie|set-cookie|session|sessionid|session_id|sid|salt|signature|sig|credentials?)("?\s*[=:]\s*(?:Some\()?"?)([^\s&,;"'}\])]+)''',
  caseSensitive: false,
);

bool _isLoopback(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' ||
      h.startsWith('127.') ||
      h == '::1' ||
      h == '[::1]' ||
      h == '0.0.0.0';
}

bool _isPublicHost(String host) {
  final h = host.toLowerCase();
  return _publicHostSuffixes.any((s) => h == s || h.endsWith('.$s'));
}

String _ipv4Label(int a, int b) {
  if (a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254) ||
      (a == 100 && b >= 64 && b <= 127)) {
    return '<lan-ip>';
  }
  return '<ip>';
}

String _redactUrl(Match m) {
  final scheme = m.group(1)!;
  var rest = m.group(2)!;
  // Trailing punctuation belongs to the sentence, not the URL.
  var tail = '';
  final trail = RegExp(r'[.,;:!?)\]}]+$').firstMatch(rest);
  if (trail != null) {
    tail = trail.group(0)!;
    rest = rest.substring(0, trail.start);
  }
  final authEnd = rest.indexOf(RegExp(r'[/?#]'));
  var authority = authEnd < 0 ? rest : rest.substring(0, authEnd);
  var after = authEnd < 0 ? '' : rest.substring(authEnd);

  var userInfo = '';
  final at = authority.lastIndexOf('@');
  if (at >= 0) {
    userInfo = '<credentials>@';
    authority = authority.substring(at + 1);
  }
  var host = authority;
  var port = '';
  final portMatch = RegExp(r':(\d{1,5})$').firstMatch(authority);
  if (portMatch != null) {
    final bracketed = authority.startsWith('[');
    final singleColon = ':'.allMatches(authority).length == 1;
    if (bracketed || authority.contains('.') || singleColon) {
      host = authority.substring(0, portMatch.start);
      port = portMatch.group(0)!;
    }
  }
  if (host.isNotEmpty && !_isLoopback(host) && !_isPublicHost(host)) {
    final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$').firstMatch(host);
    host = v4 != null
        ? _ipv4Label(int.parse(v4.group(1)!), int.parse(v4.group(2)!))
        : host.contains(':')
        ? '<ip>'
        : '<host>';
  }

  // Query values and fragments can carry tokens (Subsonic `t=`/`s=`/`p=`,
  // signed CDN links): keep the keys, drop the values.
  final q = after.indexOf('?');
  final h = after.indexOf('#');
  var path = after;
  var query = '';
  var fragment = '';
  if (h >= 0) {
    fragment = after.substring(h + 1).isEmpty ? '#' : '#<redacted>';
    path = after.substring(0, h);
  }
  if (q >= 0 && (h < 0 || q < h)) {
    query = path.substring(q + 1);
    path = path.substring(0, q);
    query =
        '?${query.split('&').map((kv) {
          final eq = kv.indexOf('=');
          if (eq < 0) return kv;
          final value = kv.substring(eq + 1);
          return value.isEmpty ? kv : '${kv.substring(0, eq)}=<redacted>';
        }).join('&')}';
  }
  return '$scheme://$userInfo$host$port$path$query$fragment$tail';
}

/// Scrubs personal data from a log line or any other diagnostic text:
///
/// * credentials in URLs, every URL query value and fragment, and the
///   host of every URL that is not loopback or a well-known public service;
/// * `password=`, `token: …`, `api_key`, cookies, `Bearer …`, JWTs;
/// * home folders (Windows user profiles, `/home/<name>`, `/Users/<name>`) and
///   UNC hosts (`\\nas\share`);
/// * IPv4 / IPv6 / MAC addresses (loopback is kept);
/// * e-mail addresses;
/// * the literal values in [context] (home path, account and host names,
///   device name, hidden device ID).
String redactDiagnostics(
  String input, [
  RedactionContext context = const RedactionContext(),
]) {
  if (input.isEmpty) return input;
  var out = input;
  out = out.replaceAllMapped(_authHeader, (m) => '${m.group(1)} <redacted>');
  out = out.replaceAll(_jwt, '<jwt>');
  out = out.replaceAllMapped(_url, _redactUrl);
  out = out.replaceAllMapped(_unc, (m) => '${m.group(1)}\\\\<host>\\');

  // Longest first, so the full home path wins over the bare account name.
  final literals = [...context.literals]
    ..sort((a, b) => b.$1.length.compareTo(a.$1.length));
  for (final (text, label) in literals) {
    out = out.replaceAll(
      RegExp(RegExp.escape(text), caseSensitive: false),
      label,
    );
  }
  out = out.replaceAllMapped(_winHome, (m) => '${m.group(1)}<user>');
  out = out.replaceAllMapped(_unixHome, (m) => '${m.group(1)}<user>');

  out = out.replaceAll(_mac, '<mac>');
  out = out.replaceAllMapped(_ipv4, (m) {
    final parts = [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
    if (parts.any((p) => p > 255)) return m.group(0)!;
    if (parts[0] == 127 || parts.every((p) => p == 0)) return m.group(0)!;
    if (parts.every((p) => p == 255)) return m.group(0)!;
    return _ipv4Label(parts[0], parts[1]);
  });
  out = out.replaceAllMapped(_ipv6Full, (m) => '<ip>');
  out = out.replaceAllMapped(_ipv6Short, (m) {
    final s = m.group(0)!;
    // `::1` is loopback; `crate::module` paths have no digits.
    if (s == '::1' || s == '::' || !s.contains(RegExp(r'\d'))) return s;
    return '<ip>';
  });
  out = out.replaceAll(_email, '<email>');
  out = out.replaceAllMapped(
    _secretKv,
    (m) => '${m.group(1)}${m.group(2)}<redacted>',
  );
  return out;
}

// ---------------------------------------------------------------------------
// Bundle
// ---------------------------------------------------------------------------

/// `lekis-diagnostics-20261127-153012.zip`
String diagnosticsFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'lekis-diagnostics-${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}.zip';
}

const _bundleReadme = '''Lekis Music diagnostics bundle / 月兔音乐诊断包

environment.txt / environment.json
  App, core and OS versions, device model, UI profile, locale, output mode,
  configured source kinds. 应用/核心/系统版本、设备型号、界面配置、语言、输出模式、音源类型。
core-log.txt
  Recent core log lines (in-memory, since the app started), redacted.
  核心最近的日志（本次启动以来，内存中），已脱敏。
context.txt (optional)
  The error shown on screen when the report was started. 发起反馈时屏幕上的错误。

Redacted / 已移除: home folders and user names, host names, IP and MAC
addresses, URL credentials, query values and private hosts, tokens and
passwords, e-mail addresses, the device ID (unless you chose to include it).
''';

/// Builds the zip. [logLines] and [problemContext] are redacted here with
/// [context]; [env] is already free of personal data.
Uint8List buildDiagnosticsZip({
  required DiagnosticsEnvironment env,
  List<String> logLines = const [],
  String? problemContext,
  RedactionContext context = const RedactionContext(),
  DateTime? now,
}) {
  final created = (now ?? DateTime.now()).toUtc().toIso8601String();
  final archive = Archive()
    ..addFile(ArchiveFile.string('README.txt', _bundleReadme))
    ..addFile(
      ArchiveFile.string(
        'environment.txt',
        '${env.toPlainText()}\nCreated: $created\n',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'environment.json',
        const JsonEncoder.withIndent(
          '  ',
        ).convert({...env.toJson(), 'created': created}),
      ),
    );
  final log = logLines.isEmpty
      ? '(no log lines / 暂无日志)\n'
      : '${logLines.map((l) => redactDiagnostics(l, context)).join('\n')}\n';
  archive.addFile(ArchiveFile.string('core-log.txt', log));
  if (problemContext != null && problemContext.trim().isNotEmpty) {
    archive.addFile(
      ArchiveFile.string(
        'context.txt',
        '${redactDiagnostics(problemContext.trim(), context)}\n',
      ),
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

// ---------------------------------------------------------------------------
// Issue
// ---------------------------------------------------------------------------

/// The issue body: the repo's bug template, the attachment reminder and the
/// environment summary (last, so it is what gets cut when space runs out).
String buildIssueBody(
  DiagnosticsEnvironment env, {
  String? bundleName,
  String? problemContext,
  int? maxEnvRows,
}) {
  final file = bundleName ?? 'lekis-diagnostics-*.zip';
  final b = StringBuffer()
    ..writeln('## Description / 问题描述')
    ..writeln('<!-- What happened, and what did you expect? / 发生了什么？你期望的结果是？ -->')
    ..writeln()
    ..writeln('## Steps to Reproduce / 复现步骤')
    ..writeln('1. ')
    ..writeln('2. ')
    ..writeln()
    ..writeln('## Diagnostic Bundle / 诊断包')
    ..writeln(
      '<!-- Drag `$file` into this box to attach it. / 请把 `$file` 拖到这里作为附件上传。 -->',
    )
    ..writeln();
  if (problemContext != null && problemContext.trim().isNotEmpty) {
    b
      ..writeln('## Error Shown / 屏幕上的错误')
      ..writeln('```text')
      ..writeln(redactDiagnostics(problemContext.trim()))
      ..writeln('```')
      ..writeln();
  }
  b
    ..writeln('## Environment / 运行环境')
    ..writeln(env.toMarkdown(maxEnvRows));
  return b.toString();
}

/// The prefilled `issues/new` link, kept under [maxLength] characters by
/// dropping the error context, then environment rows from the end, then
/// cutting the body.
Uri buildIssueUri(
  DiagnosticsEnvironment env, {
  String? bundleName,
  String? problemContext,
  String repoUrl = kLekisRepoUrl,
  String title = kIssueTitlePlaceholder,
  int maxLength = kIssueUrlMaxLength,
}) {
  String url(String body) =>
      '$repoUrl/issues/new?labels=bug'
      '&title=${Uri.encodeComponent(title)}'
      '&body=${Uri.encodeComponent(body)}';

  final rows = env.rows.length;
  for (final ctx in [problemContext, null]) {
    for (var n = rows; n >= 3; n--) {
      final s = url(
        buildIssueBody(
          env,
          bundleName: bundleName,
          problemContext: ctx,
          maxEnvRows: n,
        ),
      );
      if (s.length <= maxLength) return Uri.parse(s);
      if (ctx != null) break; // Drop the context before any env row.
    }
  }
  // Still too long (tiny limit): cut the body itself.
  var body = buildIssueBody(env, bundleName: bundleName, maxEnvRows: 3);
  while (body.isNotEmpty && url(body).length > maxLength) {
    body = body.substring(0, (body.length * 0.9).floor());
  }
  return Uri.parse(url(body));
}
