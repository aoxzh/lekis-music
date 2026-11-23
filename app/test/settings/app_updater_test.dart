import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/settings/app_updater.dart';
import 'package:lekis/src/features/settings/desktop_self_updater.dart';

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
    test('only suffixed versions see pre-releases', () {
      expect(includesPrereleases('0.2.0'), isFalse);
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

    test('prefers archive assets that in-app updates can extract', () {
      const macAssets = [
        {
          'name': 'lekis-0.3.0-macos-arm64.dmg',
          'browser_download_url': 'https://example.com/mac.dmg',
        },
        {
          'name': 'lekis-0.3.0-macos-arm64.zip',
          'browser_download_url': 'https://example.com/mac.zip',
        },
      ];
      expect(
        pickReleaseDownloadUrl(
          macAssets,
          'https://example.com/release',
          platformOverride: 'macos',
        ),
        'https://example.com/mac.zip',
      );

      const linuxAssets = [
        {
          'name': 'lekis-0.3.0-linux-x64.AppImage',
          'browser_download_url': 'https://example.com/lekis.AppImage',
        },
        {
          'name': 'lekis-0.3.0-linux-x64.tar.gz',
          'browser_download_url': 'https://example.com/lekis.tar.gz',
        },
      ];
      expect(
        pickReleaseDownloadUrl(
          linuxAssets,
          'https://example.com/release',
          platformOverride: 'linux',
        ),
        'https://example.com/lekis.tar.gz',
      );
    });

    test('pickReleaseAsset captures assetName, size and SHA256SUMS.txt', () {
      const assetsWithSums = [
        {
          'name': 'lekis-0.3.0-windows-x64.zip',
          'size': 31457280,
          'browser_download_url': 'https://example.com/win.zip',
        },
        {
          'name': 'SHA256SUMS.txt',
          'size': 380,
          'browser_download_url': 'https://example.com/SHA256SUMS.txt',
        },
      ];
      final match = pickReleaseAsset(
        assetsWithSums,
        'https://example.com/release',
        platformOverride: 'windows',
      );
      expect(match.downloadUrl, 'https://example.com/win.zip');
      expect(match.assetName, 'lekis-0.3.0-windows-x64.zip');
      expect(match.assetSize, 31457280);
      expect(match.checksumsUrl, 'https://example.com/SHA256SUMS.txt');
    });
  });

  group('parseSha256Sums', () {
    test('parses standard sha256sum output with spaces or binary star', () {
      const text = '''
1866a82e5f9ebef59165799f140d2e0f4158bca22fbdda4cd443c33f20a7f78f  lekis-0.2.0-android-arm64.apk
B062125CE0FA2C0A3EAE3F56098C378E00F6551AA1D4BA1765960931BFE13875 *lekis-0.2.0-windows-x64.zip
''';
      final sums = parseSha256Sums(text);
      expect(
        sums['lekis-0.2.0-android-arm64.apk'],
        '1866a82e5f9ebef59165799f140d2e0f4158bca22fbdda4cd443c33f20a7f78f',
      );
      expect(
        sums['lekis-0.2.0-windows-x64.zip'],
        'b062125ce0fa2c0a3eae3f56098c378e00f6551aa1d4ba1765960931bfe13875',
      );
    });
  });

  group('desktop_self_updater helpers', () {
    test('resolveMacOsAppBundle finds .app ancestor', () {
      expect(
        resolveMacOsAppBundle('/Applications/lekis.app/Contents/MacOS/lekis'),
        '/Applications/lekis.app',
      );
      expect(resolveMacOsAppBundle('/usr/local/bin/lekis'), isNull);
    });

    test('resolvePayloadRoot unwraps single top folder on Windows/Linux', () {
      final tmp = Directory.systemTemp.createTempSync('lekis-payload-test-');
      try {
        final nested = Directory('${tmp.path}${Platform.pathSeparator}lekis-0.3.0-windows-x64')
          ..createSync();
        File('${nested.path}${Platform.pathSeparator}lekis.exe')
            .writeAsStringSync('stub');
        final root = resolvePayloadRoot(tmp, os: 'windows');
        expect(root.path, nested.path);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('resolvePayloadRoot locates .app bundle on macOS', () {
      final tmp = Directory.systemTemp.createTempSync('lekis-macos-test-');
      try {
        final app = Directory('${tmp.path}${Platform.pathSeparator}lekis.app')
          ..createSync();
        final root = resolvePayloadRoot(tmp, os: 'macos');
        expect(root.path, app.path);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('apply scripts escape single quotes and reference waitPid', () {
      final win = buildWindowsApplyScript(
        waitPid: 4242,
        payloadDir: r"D:\Apps\o'brien\stage\payload",
        targetDir: r"D:\Apps\o'brien\lekis",
        executablePath: r"D:\Apps\o'brien\lekis\lekis.exe",
        stagingDir: r"D:\Apps\o'brien\stage",
      );
      expect(win, contains(r'$waitPid = 4242'));
      expect(win, contains("o''brien"));
      expect(win, contains('files replaced'));
      expect(win, contains('copy attempt'));
      expect(win, contains('relaunch failed'));
      expect(win, contains('Remove-Item -LiteralPath'));

      final mac = buildMacOsApplyScript(
        waitPid: 4242,
        payloadApp: "/tmp/o'brien/lekis.app",
        targetApp: "/Applications/lekis.app",
        stagingDir: "/tmp/o'brien",
      );
      expect(mac, contains('PID=4242'));
      expect(mac, contains(r"o'\''brien"));
    });

    test(
      'downloadAndStageDesktopUpdate verifies SHA-256 and extracts archive',
      () async {
        final tmp = Directory.systemTemp.createTempSync('lekis-e2e-update-');
        final srcDir = Directory('${tmp.path}${Platform.pathSeparator}src')
          ..createSync();
        final inner = Directory(
          '${srcDir.path}${Platform.pathSeparator}lekis-0.3.0-windows-x64',
        )..createSync();
        File('${inner.path}${Platform.pathSeparator}lekis.exe')
            .writeAsStringSync('new-binary');

        final archiveName = Platform.isWindows
            ? 'lekis-0.3.0-windows-x64.zip'
            : 'lekis-0.3.0-linux-x64.tar.gz';
        final archiveFile = File(
          '${tmp.path}${Platform.pathSeparator}$archiveName',
        );
        if (Platform.isWindows) {
          final res = await Process.run('tar', [
            '-a',
            '-cf',
            archiveFile.path,
            '-C',
            srcDir.path,
            'lekis-0.3.0-windows-x64',
          ]);
          expect(res.exitCode, 0, reason: res.stderr.toString());
        } else {
          final res = await Process.run('tar', [
            '-czf',
            archiveFile.path,
            '-C',
            srcDir.path,
            'lekis-0.3.0-windows-x64',
          ]);
          expect(res.exitCode, 0, reason: res.stderr.toString());
        }

        final realHash = await computeFileSha256(archiveFile);
        final archiveBytes = await archiveFile.readAsBytes();
        var serveTamperedHash = false;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          if (req.uri.path == '/$archiveName') {
            req.response.headers.contentLength = archiveBytes.length;
            req.response.add(archiveBytes);
            await req.response.close();
          } else if (req.uri.path == '/SHA256SUMS.txt') {
            final hash = serveTamperedHash ? '0' * 64 : realHash;
            req.response.write('$hash  $archiveName\n');
            await req.response.close();
          } else {
            req.response.statusCode = 404;
            await req.response.close();
          }
        });

        try {
          final base = 'http://127.0.0.1:${server.port}';
          final installDir = Directory(
            '${tmp.path}${Platform.pathSeparator}install',
          )..createSync();
          final stageRoot = Directory(
            '${tmp.path}${Platform.pathSeparator}stage',
          )..createSync();
          final cap = SelfUpdateCapability(
            supported: true,
            targetDir: installDir.path,
            executablePath: '${installDir.path}${Platform.pathSeparator}lekis.exe',
          );
          final info = AppUpdateInfo(
            version: '0.3.0',
            releaseUrl: '$base/release',
            downloadUrl: '$base/$archiveName',
            notes: 'Test update',
            isPrerelease: true,
            assetName: archiveName,
            assetSize: archiveBytes.length,
            checksumsUrl: '$base/SHA256SUMS.txt',
          );

          final steps = <UpdateStep>{};
          final staged = await downloadAndStageDesktopUpdate(
            info,
            capability: cap,
            stagingRootOverride: stageRoot,
            operatingSystemOverride: Platform.isWindows ? 'windows' : 'linux',
            onProgress: (p) => steps.add(p.step),
          );
          expect(
            steps,
            containsAll([
              UpdateStep.downloading,
              UpdateStep.verifying,
              UpdateStep.extracting,
            ]),
          );
          expect(
            File('${staged.payloadDir}${Platform.pathSeparator}lekis.exe')
                .readAsStringSync(),
            'new-binary',
          );

          // Tampered hash must be rejected and cleaned up.
          serveTamperedHash = true;
          await expectLater(
            downloadAndStageDesktopUpdate(
              info,
              capability: cap,
              stagingRootOverride: stageRoot,
              operatingSystemOverride: Platform.isWindows ? 'windows' : 'linux',
            ),
            throwsStateError,
          );
        } finally {
          await server.close(force: true);
          tmp.deleteSync(recursive: true);
        }
      },
    );
  });
}
