import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/settings/app_updater.dart';

void main() {
  group('compareSemVer', () {
    test('compares major, minor, patch', () {
      expect(compareSemVer('0.1.0', '0.2.0'), lessThan(0));
      expect(compareSemVer('1.0.0', '0.9.9'), greaterThan(0));
      expect(compareSemVer('v0.1.0', '0.1.0'), 0);
    });

    test('orders pre-releases before stable', () {
      expect(compareSemVer('0.1.0-alpha.1', '0.1.0-alpha.2'), lessThan(0));
      expect(compareSemVer('0.1.0-alpha.2', '0.1.0-beta.1'), lessThan(0));
      expect(compareSemVer('0.1.0-beta.1', '0.1.0'), lessThan(0));
      expect(compareSemVer('0.1.0-alpha.1', '0.1.0-alpha.10'), lessThan(0));
      expect(compareSemVer('v0.1.0-alpha.1+1', '0.1.0-alpha.1'), 0);
    });
  });

  group('includesPrereleases', () {
    test('0.x and suffixed versions see pre-releases, 1.x stable does not', () {
      expect(includesPrereleases('0.2.0'), isTrue);
      expect(includesPrereleases('0.1.0-alpha.2'), isTrue);
      expect(includesPrereleases('1.0.0-rc.1'), isTrue);
      expect(includesPrereleases('1.0.0'), isFalse);
    });
  });

  group('pickReleaseDownloadUrl', () {
    const assets = [
      {
        'name': 'lekis-0.2.0-android-arm64.apk',
        'browser_download_url': 'https://example.com/app.apk',
      },
      {
        'name': 'lekis-0.2.0-windows-x64.zip',
        'browser_download_url': 'https://example.com/win.zip',
      },
    ];

    test('selects APK on Android and ZIP on Windows', () {
      expect(
        pickReleaseDownloadUrl(
          assets,
          'https://example.com/release',
          platformOverride: 'android',
        ),
        'https://example.com/app.apk',
      );
      expect(
        pickReleaseDownloadUrl(
          assets,
          'https://example.com/release',
          platformOverride: 'windows',
        ),
        'https://example.com/win.zip',
      );
    });
  });
}
