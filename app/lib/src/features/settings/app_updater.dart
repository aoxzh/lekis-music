import 'dart:convert';
import 'dart:io';

/// Current application version (kept in sync with `app/pubspec.yaml`).
const String kLekisAppVersion = '0.1.0-alpha.2';

const String kLekisReleasesApiUrl =
    'https://api.github.com/repos/aoxzh/lekis-music/releases?per_page=10';
const String kLekisReleasesPageUrl =
    'https://github.com/aoxzh/lekis-music/releases';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.releaseUrl,
    required this.downloadUrl,
    required this.notes,
    required this.isPrerelease,
  });

  final String version;
  final String releaseUrl;
  final String downloadUrl;
  final String notes;
  final bool isPrerelease;
}

sealed class AppUpdateCheckResult {
  const AppUpdateCheckResult();
}

final class AppUpdateUpToDate extends AppUpdateCheckResult {
  const AppUpdateUpToDate(this.currentVersion);
  final String currentVersion;
}

final class AppUpdateAvailable extends AppUpdateCheckResult {
  const AppUpdateAvailable(this.info);
  final AppUpdateInfo info;
}

final class AppUpdateError extends AppUpdateCheckResult {
  const AppUpdateError(this.message);
  final String message;
}

/// Compares two semantic version strings (with optional leading `v` and
/// pre-release identifiers like `0.1.0-alpha.1`).
///
/// Returns `< 0` if [a] < [b], `0` if equal, `> 0` if [a] > [b].
int compareSemVer(String a, String b) {
  final pa = _ParsedVersion.parse(a);
  final pb = _ParsedVersion.parse(b);
  if (pa.major != pb.major) return pa.major.compareTo(pb.major);
  if (pa.minor != pb.minor) return pa.minor.compareTo(pb.minor);
  if (pa.patch != pb.patch) return pa.patch.compareTo(pb.patch);

  // Stable release > any pre-release of the same major.minor.patch.
  if (pa.prerelease.isEmpty && pb.prerelease.isEmpty) return 0;
  if (pa.prerelease.isEmpty) return 1;
  if (pb.prerelease.isEmpty) return -1;

  final len = pa.prerelease.length < pb.prerelease.length
      ? pa.prerelease.length
      : pb.prerelease.length;
  for (var i = 0; i < len; i++) {
    final segA = pa.prerelease[i];
    final segB = pb.prerelease[i];
    if (segA == segB) continue;
    final numA = int.tryParse(segA);
    final numB = int.tryParse(segB);
    if (numA != null && numB != null) return numA.compareTo(numB);
    if (numA != null) return -1;
    if (numB != null) return 1;
    return segA.compareTo(segB);
  }
  return pa.prerelease.length.compareTo(pb.prerelease.length);
}

class _ParsedVersion {
  const _ParsedVersion(this.major, this.minor, this.patch, this.prerelease);

  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;

  static _ParsedVersion parse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final plusIdx = s.indexOf('+');
    if (plusIdx != -1) s = s.substring(0, plusIdx);

    final dashIdx = s.indexOf('-');
    final corePart = dashIdx == -1 ? s : s.substring(0, dashIdx);
    final prePart = dashIdx == -1 ? '' : s.substring(dashIdx + 1);

    final nums = corePart.split('.');
    int numAt(int i) => i < nums.length ? (int.tryParse(nums[i]) ?? 0) : 0;

    return _ParsedVersion(
      numAt(0),
      numAt(1),
      numAt(2),
      prePart.isEmpty ? const [] : prePart.split('.'),
    );
  }
}

/// Picks the best platform asset download URL from a GitHub Release's `assets`.
String pickReleaseDownloadUrl(
  List<dynamic> assets,
  String fallbackReleaseUrl, {
  String? platformOverride,
}) {
  final os = platformOverride ?? Platform.operatingSystem;
  final urls = <({String name, String url})>[];
  for (final item in assets) {
    if (item is Map<String, dynamic>) {
      final name = (item['name'] as String?)?.toLowerCase() ?? '';
      final url = (item['browser_download_url'] as String?) ?? '';
      if (name.isNotEmpty && url.isNotEmpty) {
        urls.add((name: name, url: url));
      }
    }
  }

  String? firstMatch(bool Function(String name) test) {
    for (final a in urls) {
      if (test(a.name)) return a.url;
    }
    return null;
  }

  return switch (os) {
    'android' =>
      firstMatch((n) => n.endsWith('.apk') && n.contains('arm64')) ??
          firstMatch((n) => n.endsWith('.apk')) ??
          fallbackReleaseUrl,
    'windows' =>
      firstMatch((n) => n.contains('windows') && n.endsWith('.zip')) ??
          firstMatch((n) => n.endsWith('.exe') || n.endsWith('.msix')) ??
          fallbackReleaseUrl,
    'macos' =>
      firstMatch((n) => n.contains('macos') && (n.endsWith('.dmg') || n.endsWith('.zip'))) ??
          fallbackReleaseUrl,
    'linux' =>
      firstMatch(
            (n) =>
                n.contains('linux') &&
                (n.endsWith('.tar.gz') ||
                    n.endsWith('.appimage') ||
                    n.endsWith('.deb')),
          ) ??
          fallbackReleaseUrl,
    _ => fallbackReleaseUrl,
  };
}

/// Queries GitHub Releases to check whether a newer version is available.
///
/// Includes pre-releases when [currentVersion] itself is a pre-release
/// (e.g. `0.1.0-alpha.1`).
Future<AppUpdateCheckResult> checkForAppUpdate({
  String currentVersion = kLekisAppVersion,
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = 'LekisMusic/$currentVersion';
  try {
    final req = await client.getUrl(Uri.parse(kLekisReleasesApiUrl));
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final resp = await req.close().timeout(const Duration(seconds: 12));
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      return AppUpdateError('HTTP ${resp.statusCode}');
    }
    final decoded = jsonDecode(body);
    if (decoded is! List) {
      return const AppUpdateError('Unexpected response format');
    }

    final allowPrerelease = currentVersion.contains('-');
    AppUpdateInfo? newest;
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) continue;
      if (entry['draft'] == true) continue;
      final isPre = entry['prerelease'] == true;
      if (isPre && !allowPrerelease) continue;

      final tag = (entry['tag_name'] as String?)?.trim() ?? '';
      if (tag.isEmpty) continue;
      final cleanVersion = tag.startsWith('v') || tag.startsWith('V')
          ? tag.substring(1)
          : tag;
      final htmlUrl =
          (entry['html_url'] as String?)?.trim() ?? kLekisReleasesPageUrl;
      final assets = (entry['assets'] as List?) ?? const [];
      final downloadUrl = pickReleaseDownloadUrl(assets, htmlUrl);
      final notes = ((entry['body'] as String?) ?? '').trim();

      if (newest == null || compareSemVer(cleanVersion, newest.version) > 0) {
        newest = AppUpdateInfo(
          version: cleanVersion,
          releaseUrl: htmlUrl,
          downloadUrl: downloadUrl,
          notes: notes,
          isPrerelease: isPre,
        );
      }
    }

    if (newest == null || compareSemVer(newest.version, currentVersion) <= 0) {
      return AppUpdateUpToDate(currentVersion);
    }
    return AppUpdateAvailable(newest);
  } catch (e) {
    return AppUpdateError(e.toString());
  } finally {
    client.close(force: true);
  }
}
