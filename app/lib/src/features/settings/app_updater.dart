import 'dart:convert';
import 'dart:io';

/// Current application version (kept in sync with `app/pubspec.yaml`).
const String kLekisAppVersion = '0.2.83';

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
    this.assetName,
    this.assetSize,
    this.checksumsUrl,
  });

  final String version;
  final String releaseUrl;
  final String downloadUrl;
  final String notes;
  final bool isPrerelease;
  final String? assetName;
  final int? assetSize;
  final String? checksumsUrl;
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

typedef ReleaseAssetMatch = ({
  String downloadUrl,
  String? assetName,
  int? assetSize,
  String? checksumsUrl,
});

/// Picks the best platform asset and `SHA256SUMS.txt` URL from a GitHub
/// Release's `assets`.
///
/// In-app updates need an archive they can extract, so ZIP (Windows/macOS) and
/// tar.gz (Linux) win over install-only formats such as EXE, DMG or AppImage.
ReleaseAssetMatch pickReleaseAsset(
  List<dynamic> assets,
  String fallbackReleaseUrl, {
  String? platformOverride,
}) {
  final os = platformOverride ?? Platform.operatingSystem;
  final entries =
      <({String rawName, String lowerName, String url, int? size})>[];
  String? checksumsUrl;
  for (final item in assets) {
    if (item is Map<String, dynamic>) {
      final rawName = (item['name'] as String?)?.trim() ?? '';
      final lowerName = rawName.toLowerCase();
      final url = (item['browser_download_url'] as String?) ?? '';
      final size = (item['size'] as num?)?.toInt();
      if (rawName.isNotEmpty && url.isNotEmpty) {
        if (lowerName == 'sha256sums.txt') {
          checksumsUrl = url;
        }
        entries.add((
          rawName: rawName,
          lowerName: lowerName,
          url: url,
          size: size,
        ));
      }
    }
  }

  ({String rawName, String lowerName, String url, int? size})? firstMatch(
    bool Function(String lowerName) test,
  ) {
    for (final a in entries) {
      if (test(a.lowerName)) return a;
    }
    return null;
  }

  final matched = switch (os) {
    'android' =>
      firstMatch((n) => n.endsWith('.apk') && n.contains('arm64')) ??
          firstMatch((n) => n.endsWith('.apk')),
    'windows' =>
      firstMatch((n) => n.contains('windows') && n.endsWith('.zip')) ??
          firstMatch((n) => n.endsWith('.exe') || n.endsWith('.msix')),
    // In-app updates replace the extracted .app, so prefer the zip even when
    // the release also ships a drag-to-Applications dmg.
    'macos' =>
      firstMatch((n) => n.contains('macos') && n.endsWith('.zip')) ??
          firstMatch(
            (n) =>
                n.contains('macos') &&
                (n.endsWith('.dmg') || n.endsWith('.zip')),
          ),
    // Same rule on Linux: tar.gz is the in-place update payload; AppImage and
    // deb are install formats and only used when no tar.gz was published.
    'linux' =>
      firstMatch((n) => n.contains('linux') && n.endsWith('.tar.gz')) ??
          firstMatch(
            (n) =>
                n.contains('linux') &&
                (n.endsWith('.appimage') || n.endsWith('.deb')),
          ),
    _ => null,
  };

  return (
    downloadUrl: matched?.url ?? fallbackReleaseUrl,
    assetName: matched?.rawName,
    assetSize: matched?.size,
    checksumsUrl: checksumsUrl,
  );
}

/// Picks the best platform asset download URL from a GitHub Release's `assets`.
String pickReleaseDownloadUrl(
  List<dynamic> assets,
  String fallbackReleaseUrl, {
  String? platformOverride,
}) => pickReleaseAsset(
  assets,
  fallbackReleaseUrl,
  platformOverride: platformOverride,
).downloadUrl;

/// Parses `sha256sum` output (`<64-hex>  <filename>` or `*<filename>`) into a
/// map of lowercased filename → lowercased hex digest.
Map<String, String> parseSha256Sums(String body) {
  final result = <String, String>{};
  final pattern = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$');
  for (final rawLine in body.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = pattern.firstMatch(line);
    if (match == null) continue;
    final hash = match.group(1)!.toLowerCase();
    final name = match.group(2)!.trim();
    if (name.isNotEmpty) {
      result[name.toLowerCase()] = hash;
    }
  }
  return result;
}

/// Whether a build at [currentVersion] should be offered GitHub
/// pre-releases: only versions with a `-beta` / `-rc` suffix do. Stable 0.x
/// releases are published as regular releases (see release.yml), so they must
/// not opt into pre-release candidates.
bool includesPrereleases(String currentVersion) {
  final v = currentVersion.startsWith('v')
      ? currentVersion.substring(1)
      : currentVersion;
  return v.contains('-');
}

/// Queries GitHub Releases to check whether a newer version is available.
///
/// Includes pre-releases per [includesPrereleases].
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

    final allowPrerelease = includesPrereleases(currentVersion);
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
      final asset = pickReleaseAsset(assets, htmlUrl);
      final notes = ((entry['body'] as String?) ?? '').trim();

      if (newest == null || compareSemVer(cleanVersion, newest.version) > 0) {
        newest = AppUpdateInfo(
          version: cleanVersion,
          releaseUrl: htmlUrl,
          downloadUrl: asset.downloadUrl,
          notes: notes,
          isPrerelease: isPre,
          assetName: asset.assetName,
          assetSize: asset.assetSize,
          checksumsUrl: asset.checksumsUrl,
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
