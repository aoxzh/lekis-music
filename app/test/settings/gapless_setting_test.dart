// Settings → Playback → Gapless: the switch writes `playback.gapless` to the
// core (which applies it to the running engine), and reflects the stored value.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_controller.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/enrich/enrich_providers.dart';
import 'package:lekis/src/features/settings/settings_page.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/settings/strings.dart';
import 'package:lekis/src/features/settings/usb_bit_perfect_providers.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Core settings store: records every write so the test can see what the
/// switch sent. Everything else the page asks the core for is unsupported.
class _CoreSettings implements RustLibApi {
  _CoreSettings(this.values);

  final Map<String, String> values;
  final writes = <(String, String)>[];

  @override
  Future<String?> crateApiCoreGetSetting({required String key}) async =>
      values[key];

  @override
  Future<void> crateApiCoreSetSetting({
    required String key,
    required String value,
  }) async {
    writes.add((key, value));
    values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSources extends SourcesNotifier {
  @override
  Future<List<SourceConfigDto>> build() async => const [];
}

class _FakePending extends EnrichPendingCountNotifier {
  @override
  int? build() => 0;
}

Widget _app() => ProviderScope(
  overrides: [
    usbBitPerfectSupportedProvider.overrideWithValue(false),
    desktopLyricsSupportedProvider.overrideWithValue(false),
    sourcesProvider.overrideWith(_FakeSources.new),
    enrichPendingCountProvider.overrideWith(_FakePending.new),
    downloadsSummaryProvider.overrideWithValue((
      readyCount: 0,
      totalBytes: 0,
      activeCount: 0,
    )),
    aboutInfoProvider.overrideWithValue(
      const AboutInfo(coreVersion: '9.9.9', deviceId: 'dev-1'),
    ),
  ],
  child: MaterialApp(
    theme: lekisDarkTheme(),
    home: const Material(child: SettingsPage()),
  ),
);

Finder get _gaplessSwitch => find.descendant(
  of: find.widgetWithText(SettingsSwitchTile, SettingsStrings.gapless),
  matching: find.byType(Switch),
);

Future<void> _pumpPlayback(WidgetTester tester, _CoreSettings core) async {
  RustLib.initMock(api: core);
  addTearDown(RustLib.dispose);
  UiProfile.debugOverride = UiProfile.desktop;
  addTearDown(() => UiProfile.debugOverride = null);
  tester.view.physicalSize = const Size(1280, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // Desktop settings open on Playback.
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
  expect(_gaplessSwitch, findsOneWidget);
}

void main() {
  testWidgets('gapless defaults on; toggling writes playback.gapless to core', (
    tester,
  ) async {
    final core = _CoreSettings({});
    await _pumpPlayback(tester, core);
    expect(tester.widget<Switch>(_gaplessSwitch).value, isTrue);

    await tester.tap(_gaplessSwitch);
    await tester.pumpAndSettle();
    expect(core.writes, [(SettingKeys.gapless, 'false')]);
    expect(SettingKeys.gapless, 'playback.gapless');
    expect(tester.widget<Switch>(_gaplessSwitch).value, isFalse);

    await tester.tap(_gaplessSwitch);
    await tester.pumpAndSettle();
    expect(core.writes, [
      (SettingKeys.gapless, 'false'),
      (SettingKeys.gapless, 'true'),
    ]);
    expect(tester.widget<Switch>(_gaplessSwitch).value, isTrue);
  });

  testWidgets('a stored "false" shows the switch off', (tester) async {
    final core = _CoreSettings({SettingKeys.gapless: 'false'});
    await _pumpPlayback(tester, core);
    expect(tester.widget<Switch>(_gaplessSwitch).value, isFalse);
    expect(core.writes, isEmpty);
  });
}
