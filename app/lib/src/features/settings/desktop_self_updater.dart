// 桌面端在线自更新（参考 yetone/magpie 的「下载 → 校验 SHA-256 → 解压暂存 → 重启替换」模式）。
//
// - Windows：解压 zip 到临时暂存目录，重启时由独立后台脚本等待当前进程退出、覆盖安装目录并重新启动 `lekis.exe`。
// - macOS：用 `ditto` 解压 `.app` 并清除 quarantine 属性，重启时原子替换 `.app` 包并用 `open -n` 拉起。
// - Linux：解压 tar.gz 到暂存目录，重启时等待退出、覆盖目录并重新启动 `lekis`。
// - 只读安装目录（例如 macOS 从 DMG 运行、或无写权限的 Program Files）自动降级为打开下载页。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../l10n/app_l10n.dart';
import 'app_updater.dart';

enum UpdateStep { downloading, verifying, extracting }

class UpdateDownloadProgress {
  const UpdateDownloadProgress({
    required this.step,
    required this.receivedBytes,
    required this.totalBytes,
    this.bytesPerSecond = 0,
  });

  final UpdateStep step;
  final int receivedBytes;
  final int totalBytes;
  final double bytesPerSecond;

  double? get fraction =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

class UpdateCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class UpdateCancelledException implements Exception {
  const UpdateCancelledException();
}

class SelfUpdateCapability {
  const SelfUpdateCapability({
    required this.supported,
    this.targetDir,
    this.executablePath,
    this.reason,
  });

  final bool supported;
  final String? targetDir;
  final String? executablePath;
  final String? reason;
}

class StagedDesktopUpdate {
  const StagedDesktopUpdate({
    required this.version,
    required this.stagingDir,
    required this.payloadDir,
    required this.targetDir,
    required this.executablePath,
    required this.operatingSystem,
  });

  final String version;
  final String stagingDir;
  final String payloadDir;
  final String targetDir;
  final String executablePath;
  final String operatingSystem;
}

/// Resolves the macOS `.app` bundle path if [executablePath] lives inside one
/// (e.g. `/Applications/lekis.app/Contents/MacOS/lekis` → `/Applications/lekis.app`).
String? resolveMacOsAppBundle(String executablePath) {
  var current = File(executablePath).parent;
  for (var i = 0; i < 6; i++) {
    final name = current.path
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty)
        .lastOrNull;
    if (name != null && name.toLowerCase().endsWith('.app')) {
      return current.path;
    }
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return null;
}

/// Resolves the actual installable root inside an extracted archive directory.
///
/// - On macOS: locates the extracted `*.app` bundle (top-level or one level deep).
/// - On Windows/Linux: unwraps a single top-level wrapper folder (such as
///   `lekis-0.2.0-windows-x64/` or `lekis-0.2.0-linux-x64/`).
Directory resolvePayloadRoot(Directory extracted, {required String os}) {
  final entries = extracted.listSync(followLinks: false);
  final dirs = entries.whereType<Directory>().where((d) {
    final base = _basename(d.path);
    return base != '__MACOSX' && !base.startsWith('.');
  }).toList();
  final files = entries.whereType<File>().where((f) {
    return !_basename(f.path).startsWith('.');
  }).toList();

  if (os == 'macos') {
    for (final d in dirs) {
      if (_basename(d.path).toLowerCase().endsWith('.app')) return d;
    }
    for (final d in dirs) {
      for (final sub in d.listSync(followLinks: false).whereType<Directory>()) {
        if (_basename(sub.path).toLowerCase().endsWith('.app')) return sub;
      }
    }
    throw StateError(
      L10n.tr('更新包中未找到 .app 应用包', 'No .app bundle found in update archive'),
    );
  }

  if (files.isEmpty && dirs.length == 1) {
    return dirs.first;
  }
  return extracted;
}

/// Checks whether the current desktop installation can be updated in place.
SelfUpdateCapability checkSelfUpdateCapability({
  String? resolvedExecutableOverride,
  String? operatingSystemOverride,
}) {
  final os = operatingSystemOverride ?? Platform.operatingSystem;
  if (os != 'windows' && os != 'macos' && os != 'linux') {
    return const SelfUpdateCapability(supported: false);
  }

  final exe = resolvedExecutableOverride ?? Platform.resolvedExecutable;
  if (exe.isEmpty) {
    return const SelfUpdateCapability(supported: false);
  }

  if (os == 'macos') {
    final bundle = resolveMacOsAppBundle(exe);
    if (bundle == null) {
      return SelfUpdateCapability(
        supported: false,
        reason: L10n.tr(
          '当前并非从 .app 应用包运行，请前往下载页更新',
          'Not running from a .app bundle; please update from the release page',
        ),
      );
    }
    if (bundle.startsWith('/Volumes/') || bundle.contains('/AppTranslocation/')) {
      return SelfUpdateCapability(
        supported: false,
        reason: L10n.tr(
          '当前从只读镜像运行，请先拖入“应用程序”后再在线更新',
          'Running from a read-only image; move the app to Applications first',
        ),
      );
    }
    final parentDir = Directory(bundle).parent;
    if (!_probeWritable(parentDir)) {
      return SelfUpdateCapability(
        supported: false,
        reason: L10n.tr(
          '应用所在目录没有写入权限，请手动下载更新',
          'Install folder is not writable; please download the update manually',
        ),
      );
    }
    return SelfUpdateCapability(
      supported: true,
      targetDir: bundle,
      executablePath: bundle,
    );
  }

  final installDir = File(exe).parent;
  if (!_probeWritable(installDir)) {
    return SelfUpdateCapability(
      supported: false,
      reason: L10n.tr(
        '应用所在目录没有写入权限，请手动下载更新',
        'Install folder is not writable; please download the update manually',
      ),
    );
  }
  return SelfUpdateCapability(
    supported: true,
    targetDir: installDir.path,
    executablePath: exe,
  );
}

bool _probeWritable(Directory dir) {
  if (!dir.existsSync()) return false;
  final probe = File(
    '${dir.path}${Platform.pathSeparator}.lekis-update-probe-$pid',
  );
  try {
    probe.writeAsStringSync('ok');
    probe.deleteSync();
    return true;
  } catch (_) {
    try {
      if (probe.existsSync()) probe.deleteSync();
    } catch (_) {}
    return false;
  }
}

/// Downloads, SHA-256 verifies, and extracts a desktop update into a staging
/// directory ready for restart.
Future<StagedDesktopUpdate> downloadAndStageDesktopUpdate(
  AppUpdateInfo info, {
  required SelfUpdateCapability capability,
  void Function(UpdateDownloadProgress progress)? onProgress,
  UpdateCancelToken? cancelToken,
  Directory? stagingRootOverride,
  String? operatingSystemOverride,
}) async {
  if (!capability.supported ||
      capability.targetDir == null ||
      capability.executablePath == null) {
    throw StateError(
      capability.reason ??
          L10n.tr('当前环境不支持在线自更新', 'In-app update is not supported here'),
    );
  }

  final os = operatingSystemOverride ?? Platform.operatingSystem;
  final assetName =
      info.assetName ??
      Uri.tryParse(info.downloadUrl)?.pathSegments.lastOrNull ??
      'lekis-update.bin';

  final root = stagingRootOverride ?? Directory.systemTemp;
  final safeVersion = info.version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
  final stagingDir = Directory(
    '${root.path}${Platform.pathSeparator}lekis-update-$safeVersion',
  );
  if (stagingDir.existsSync()) {
    await stagingDir.delete(recursive: true);
  }
  await stagingDir.create(recursive: true);

  final archiveFile = File(
    '${stagingDir.path}${Platform.pathSeparator}$assetName',
  );
  final partFile = File('${archiveFile.path}.part');

  try {
    await _downloadFile(
      info.downloadUrl,
      partFile,
      expectedSize: info.assetSize ?? 0,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    if (cancelToken?.isCancelled == true) {
      throw const UpdateCancelledException();
    }
    await partFile.rename(archiveFile.path);

    final finalSize = await archiveFile.length();
    if (info.checksumsUrl != null && info.checksumsUrl!.isNotEmpty) {
      onProgress?.call(
        UpdateDownloadProgress(
          step: UpdateStep.verifying,
          receivedBytes: finalSize,
          totalBytes: finalSize,
        ),
      );
      await _verifyArchiveChecksum(
        archiveFile,
        assetName: assetName,
        checksumsUrl: info.checksumsUrl!,
        os: os,
      );
    }

    if (cancelToken?.isCancelled == true) {
      throw const UpdateCancelledException();
    }

    onProgress?.call(
      UpdateDownloadProgress(
        step: UpdateStep.extracting,
        receivedBytes: finalSize,
        totalBytes: finalSize,
      ),
    );
    final extractedDir = Directory(
      '${stagingDir.path}${Platform.pathSeparator}extracted',
    );
    await extractedDir.create(recursive: true);
    await _extractArchive(archiveFile, extractedDir, os: os);

    if (os == 'macos') {
      // Remove quarantine extended attribute so macOS doesn't block relaunch.
      await Process.run('xattr', ['-dr', 'com.apple.quarantine', extractedDir.path]);
    }

    final payloadDir = resolvePayloadRoot(extractedDir, os: os);
    return StagedDesktopUpdate(
      version: info.version,
      stagingDir: stagingDir.path,
      payloadDir: payloadDir.path,
      targetDir: capability.targetDir!,
      executablePath: capability.executablePath!,
      operatingSystem: os,
    );
  } catch (_) {
    try {
      if (stagingDir.existsSync()) {
        await stagingDir.delete(recursive: true);
      }
    } catch (_) {}
    rethrow;
  }
}

Future<void> _downloadFile(
  String url,
  File destination, {
  required int expectedSize,
  void Function(UpdateDownloadProgress progress)? onProgress,
  UpdateCancelToken? cancelToken,
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'LekisMusic/$kLekisAppVersion';
  IOSink? sink;
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.followRedirects = true;
    req.maxRedirects = 8;
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(url));
    }

    final totalBytes = resp.contentLength > 0 ? resp.contentLength : expectedSize;
    sink = destination.openWrite();

    var received = 0;
    final stopwatch = Stopwatch()..start();
    var lastEmitMs = 0;

    onProgress?.call(
      UpdateDownloadProgress(
        step: UpdateStep.downloading,
        receivedBytes: 0,
        totalBytes: totalBytes,
      ),
    );

    await for (final chunk in resp) {
      if (cancelToken?.isCancelled == true) {
        throw const UpdateCancelledException();
      }
      sink.add(chunk);
      received += chunk.length;
      final elapsedMs = stopwatch.elapsedMilliseconds;
      if (elapsedMs - lastEmitMs >= 150 ||
          (totalBytes > 0 && received >= totalBytes)) {
        lastEmitMs = elapsedMs;
        final speed = elapsedMs > 0 ? received * 1000.0 / elapsedMs : 0.0;
        onProgress?.call(
          UpdateDownloadProgress(
            step: UpdateStep.downloading,
            receivedBytes: received,
            totalBytes: totalBytes,
            bytesPerSecond: speed,
          ),
        );
      }
    }
    await sink.flush();
    await sink.close();
    sink = null;
  } finally {
    try {
      await sink?.close();
    } catch (_) {}
    client.close(force: true);
  }
}

Future<void> _verifyArchiveChecksum(
  File archiveFile, {
  required String assetName,
  required String checksumsUrl,
  required String os,
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'LekisMusic/$kLekisAppVersion';
  String body;
  try {
    final req = await client.getUrl(Uri.parse(checksumsUrl));
    req.followRedirects = true;
    final resp = await req.close().timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw HttpException(
        'SHA256SUMS HTTP ${resp.statusCode}',
        uri: Uri.parse(checksumsUrl),
      );
    }
    body = await resp.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }

  final sums = parseSha256Sums(body);
  final expected = sums[assetName.toLowerCase()];
  if (expected == null) {
    return;
  }

  final actual = await computeFileSha256(archiveFile, os: os);
  if (actual.toLowerCase() != expected.toLowerCase()) {
    throw StateError(
      L10n.tr(
        '安装包 SHA-256 校验失败，已中止更新',
        'Update archive SHA-256 verification failed',
      ),
    );
  }
}

/// Computes the lowercase hex SHA-256 digest of [file] using native OS tools.
Future<String> computeFileSha256(File file, {String? os}) async {
  final platform = os ?? Platform.operatingSystem;
  final hexPattern = RegExp(r'\b([0-9a-fA-F]{64})\b');

  ProcessResult res;
  if (platform == 'windows') {
    res = await Process.run('certutil', ['-hashfile', file.path, 'SHA256']);
    if (res.exitCode != 0) {
      res = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "(Get-FileHash -Algorithm SHA256 -LiteralPath '${_psEscape(file.path)}').Hash",
      ]);
    }
  } else if (platform == 'macos') {
    res = await Process.run('shasum', ['-a', '256', file.path]);
  } else {
    res = await Process.run('sha256sum', [file.path]);
  }

  if (res.exitCode != 0) {
    throw StateError('SHA-256 check failed: ${res.stderr}');
  }
  final stdout = res.stdout.toString();
  for (final line in stdout.split('\n')) {
    final m = hexPattern.firstMatch(line.trim());
    if (m != null) return m.group(1)!.toLowerCase();
  }
  throw StateError('Could not parse SHA-256 output');
}

Future<void> _extractArchive(
  File archive,
  Directory targetDir, {
  required String os,
}) async {
  final lower = archive.path.toLowerCase();
  ProcessResult res;
  if (os == 'windows') {
    // Windows 10 1803+ / Windows 11 ship bsdtar (`tar.exe`), much faster than Expand-Archive.
    res = await Process.run('tar', ['-xf', archive.path, '-C', targetDir.path]);
    if (res.exitCode != 0) {
      res = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Expand-Archive -LiteralPath '${_psEscape(archive.path)}' -DestinationPath '${_psEscape(targetDir.path)}' -Force",
      ]);
    }
  } else if (os == 'macos' && lower.endsWith('.zip')) {
    res = await Process.run('ditto', ['-x', '-k', archive.path, targetDir.path]);
  } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
    res = await Process.run('tar', ['-xzf', archive.path, '-C', targetDir.path]);
  } else if (lower.endsWith('.zip')) {
    res = await Process.run('unzip', ['-q', archive.path, '-d', targetDir.path]);
  } else {
    throw UnsupportedError('Unsupported archive format: ${archive.path}');
  }

  if (res.exitCode != 0) {
    throw StateError(
      L10n.tr(
        '解压更新包失败：${res.stderr}',
        'Failed to extract update archive: ${res.stderr}',
      ),
    );
  }
}

/// Arguments for `cmd.exe` that start the apply script in an independent
/// process. `start` detaches it from Lekis's console/job so quitting the app
/// does not kill the updater before it can replace the files.
List<String> windowsApplyHelperCommand(String scriptPath) => [
  '/c',
  'start',
  '',
  '/min',
  'powershell',
  '-NoProfile',
  '-ExecutionPolicy',
  'Bypass',
  '-WindowStyle',
  'Hidden',
  '-File',
  scriptPath,
];

/// Best-effort diagnostics for the Windows self-updater.
void _appendUpdateLog(String message) {
  try {
    final base = Platform.environment['LOCALAPPDATA'];
    if (base == null || base.isEmpty) return;
    final dir = Directory('$base\\Lekis');
    dir.createSync(recursive: true);
    File('${dir.path}\\update.log').writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
    );
  } catch (_) {
    // Diagnostics must never break the update itself.
  }
}

/// Spawns a detached OS helper script to wait for the current process to exit,
/// replace the installed files with [staged], relaunch Lekis, and clean up.
Future<void> applyStagedDesktopUpdateAndRelaunch(
  StagedDesktopUpdate staged, {
  bool exitProcess = true,
  int? waitForPidOverride,
}) async {
  final waitPid = waitForPidOverride ?? pid;
  if (staged.operatingSystem == 'windows') {
    final script = File('${staged.stagingDir}\\apply.ps1');
    await script.writeAsString(
      buildWindowsApplyScript(
        waitPid: waitPid,
        payloadDir: staged.payloadDir,
        targetDir: staged.targetDir,
        executablePath: staged.executablePath,
        stagingDir: staged.stagingDir,
      ),
    );
    _appendUpdateLog(
      'launching helper for ${staged.version} (wait pid $waitPid)',
    );
    // A plain detached PowerShell keeps the parent's console/job and is killed
    // as soon as Lekis exits (observed on Windows 11: the helper never reached
    // its first log line). `start` gives it an independent process.
    await Process.start(
      'cmd.exe',
      windowsApplyHelperCommand(script.path),
      mode: ProcessStartMode.detached,
    );
    _appendUpdateLog('helper spawned');
  } else if (staged.operatingSystem == 'macos') {
    final script = File('${staged.stagingDir}/apply.sh');
    await script.writeAsString(
      buildMacOsApplyScript(
        waitPid: waitPid,
        payloadApp: staged.payloadDir,
        targetApp: staged.targetDir,
        stagingDir: staged.stagingDir,
      ),
    );
    await Process.start(
      '/bin/sh',
      [script.path],
      mode: ProcessStartMode.detached,
    );
  } else if (staged.operatingSystem == 'linux') {
    final script = File('${staged.stagingDir}/apply.sh');
    await script.writeAsString(
      buildLinuxApplyScript(
        waitPid: waitPid,
        payloadDir: staged.payloadDir,
        targetDir: staged.targetDir,
        executablePath: staged.executablePath,
        stagingDir: staged.stagingDir,
      ),
    );
    await Process.start(
      '/bin/sh',
      [script.path],
      mode: ProcessStartMode.detached,
    );
  } else {
    throw UnsupportedError(
      'Unsupported platform for self-update: ${staged.operatingSystem}',
    );
  }

  if (exitProcess) {
    exit(0);
  }
}

String buildWindowsApplyScript({
  required int waitPid,
  required String payloadDir,
  required String targetDir,
  required String executablePath,
  required String stagingDir,
}) {
  final pPayload = _psEscape(payloadDir);
  final pTarget = _psEscape(targetDir);
  final pExe = _psEscape(executablePath);
  final pStage = _psEscape(stagingDir);
  return '''
\$ErrorActionPreference = 'Stop'
\$logDir = Join-Path \$env:LOCALAPPDATA 'Lekis'
New-Item -ItemType Directory -Force -Path \$logDir | Out-Null
\$log = Join-Path \$logDir 'update.log'
function Log(\$message) {
  try { Add-Content -LiteralPath \$log -Value ("{0:o} {1}" -f (Get-Date), \$message) } catch {}
}
Log 'waiting for Lekis to exit'
\$waitPid = $waitPid
for (\$i = 0; \$i -lt 240; \$i++) {
  if (-not (Get-Process -Id \$waitPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 250
}
Start-Sleep -Milliseconds 300
\$copied = \$false
for (\$attempt = 1; \$attempt -le 60; \$attempt++) {
  try {
    Copy-Item -Path '$pPayload\\*' -Destination '$pTarget' -Recurse -Force -ErrorAction Stop
    \$copied = \$true
    break
  } catch {
    if (\$attempt -eq 1 -or (\$attempt % 10) -eq 0) {
      Log ("copy attempt \$attempt failed: " + \$_.Exception.Message)
    }
    Start-Sleep -Milliseconds 500
  }
}
if (\$copied) { Log 'files replaced' } else { Log 'copy failed after retries' }
try {
  Start-Process -FilePath '$pExe' -WorkingDirectory '$pTarget'
  Log 'relaunched Lekis'
} catch {
  Log ('relaunch failed: ' + \$_.Exception.Message)
}
Start-Sleep -Milliseconds 500
if (\$copied) {
  Remove-Item -LiteralPath '$pStage' -Recurse -Force -ErrorAction SilentlyContinue
}
''';
}

String buildMacOsApplyScript({
  required int waitPid,
  required String payloadApp,
  required String targetApp,
  required String stagingDir,
}) {
  final sPayload = _shEscape(payloadApp);
  final sTarget = _shEscape(targetApp);
  final sBackup = _shEscape('$targetApp.lekis-old');
  final sStage = _shEscape(stagingDir);
  return '''
#!/bin/sh
set -e
PID=$waitPid
i=0
while kill -0 "\$PID" 2>/dev/null && [ "\$i" -lt 80 ]; do
  sleep 0.25
  i=\$((i + 1))
done
rm -rf '$sBackup'
mv '$sTarget' '$sBackup'
if mv '$sPayload' '$sTarget'; then
  rm -rf '$sBackup'
else
  mv '$sBackup' '$sTarget'
  exit 1
fi
open -n '$sTarget'
rm -rf '$sStage'
''';
}

String buildLinuxApplyScript({
  required int waitPid,
  required String payloadDir,
  required String targetDir,
  required String executablePath,
  required String stagingDir,
}) {
  final sPayload = _shEscape(payloadDir);
  final sTarget = _shEscape(targetDir);
  final sExe = _shEscape(executablePath);
  final sStage = _shEscape(stagingDir);
  return '''
#!/bin/sh
set -e
PID=$waitPid
i=0
while kill -0 "\$PID" 2>/dev/null && [ "\$i" -lt 80 ]; do
  sleep 0.25
  i=\$((i + 1))
done
cp -a '$sPayload'/. '$sTarget'/
nohup '$sExe' >/dev/null 2>&1 &
rm -rf '$sStage'
''';
}

String _psEscape(String s) => s.replaceAll("'", "''");
String _shEscape(String s) => s.replaceAll("'", r"'\''");
String _basename(String path) =>
    path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ?? '';
