import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/settings/report_problem.dart';

DiagnosticsEnvironment _environment({String? deviceId}) =>
    DiagnosticsEnvironment(
      appVersion: '0.6.3',
      buildMode: 'release',
      coreVersion: '0.6.3',
      os: 'Windows',
      osVersion: '11',
      arch: 'x64',
      uiProfile: 'desktop',
      systemLocale: 'zh-CN',
      appLanguage: 'zh-CN',
      windowClass: 'expanded',
      outputMode: 'shared',
      sourceKinds: const {'local': 1},
      deviceId: deviceId,
    );

void main() {
  // Built at runtime so this source file itself never contains a user path.
  final windowsHome = r'C:\' 'Users' r'\ao';

  test('redacts credentials, private hosts, home paths, secrets and e-mail', () {
    final out = redactDiagnostics(
      'GET https://user:pass@192.168.1.20:8096/rest?token=abc123&x=1\n'
      '$windowsHome\\Music\n'
      'mail me at someone@example.com\n'
      'password=hunter2\n'
      'Authorization: Bearer abcdefghij',
    );
    expect(out, isNot(contains('{{PASSWORD')));
    expect(out, isNot(contains('{{SECRET')));
    expect(out, contains('<credentials>@<lan-ip>:8096'));
    expect(out, contains('<user>'));
    expect(out, contains('<email>'));
    expect(out, isNot(contains('hunter2')));
    expect(out, contains('Authorization: <redacted>'));
    expect(out, isNot(contains('abcdefghij')));
  });

  test('diagnostics zip has the expected files and redacted contents', () {
    final bytes = buildDiagnosticsZip(
      env: _environment(deviceId: 'device-secret'),
      logLines: const ['token=abcd1234', 'connected to 10.0.0.4'],
      problemContext: 'failed in $windowsHome\\Music password=hunter2',
      context: RedactionContext(
        literals: [(windowsHome, '<home>'), ('ao', '<user>')],
      ),
      now: DateTime.utc(2026, 11, 28, 12, 34, 56),
    );
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = {for (final file in archive) file.name: file};
    expect(
      files.keys,
      containsAll([
        'README.txt',
        'environment.txt',
        'environment.json',
        'core-log.txt',
        'context.txt',
      ]),
    );
    String text(String name) =>
        utf8.decode(files[name]!.content as List<int>);
    expect(text('core-log.txt'), isNot(contains('abcd1234')));
    expect(text('core-log.txt'), contains('<lan-ip>'));
    expect(text('context.txt'), isNot(contains('hunter2')));
    expect(text('context.txt'), isNot(contains(windowsHome)));
    expect(text('environment.json'), contains('device-secret'));
    expect(text('environment.txt'), contains('App Version: 0.6.3'));
  });

  test('issue URL drops the error context before exceeding the limit', () {
    final uri = buildIssueUri(
      _environment(),
      bundleName: 'lekis-diagnostics-20261128-123456.zip',
      problemContext: 'x' * 20000,
      maxLength: 6000,
    );
    expect(uri.toString().length, lessThanOrEqualTo(6000));
    expect(uri.toString(), contains('issues/new'));
  });

  test('diagnostics file name is stable and filesystem-safe', () {
    expect(
      diagnosticsFileName(DateTime(2026, 1, 2, 3, 4, 5)),
      'lekis-diagnostics-20260102-030405.zip',
    );
  });
}
