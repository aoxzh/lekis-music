import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/plugins/plugin_detail_sheet.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _Api implements RustLibApi {
  final calls = <bool>[];
  Completer<void>? pending;
  bool fail = false;
  @override
  Future<List<PluginSettingDto>> crateApiCorePluginSettings({
    required String pluginId,
  }) async => [];
  @override
  Future<void> crateApiCoreSetPluginNativeAndroidAllowed({
    required String pluginId,
    required bool allowed,
  }) async {
    expect(pluginId, 'dev.test.native');
    calls.add(allowed);
    if (fail) throw StateError('Save failed');
    await pending?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _plugin = PluginInfoDto(
  id: 'dev.test.native',
  name: 'Native source',
  version: '1.0.0',
  apiVersion: '1.2',
  runtime: 'js',
  kinds: ['source'],
  enabled: true,
  nativeAndroidGranted: false,
  directory: 'dev.test.native',
  permissions: PluginPermissionsDto(
    network: [],
    process: ['yt-dlp'],
    requestHeaderHosts: [],
    webSignIn: false,
    nativeAndroid: true,
    storageKb: 64,
  ),
  settings: [],
);
void main() {
  late _Api api;
  setUp(() {
    api = _Api();
    RustLib.initMock(api: api);
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    RustLib.dispose();
  });
  Future<void> mount(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: lekisLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPluginDetailSheet(context, _plugin),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SettingsSwitchTile));
  }

  testWidgets('native grant defaults off and awaits host before updating', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('允许启动 yt-dlp'), findsNothing);
    expect(find.textContaining('与应用拥有相同权限'), findsOneWidget);
    expect(
      tester.widget<SettingsSwitchTile>(find.byType(SettingsSwitchTile)).value,
      isFalse,
    );
    api.pending = Completer<void>();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(api.calls, [true]);
    expect(
      tester
          .widget<SettingsSwitchTile>(find.byType(SettingsSwitchTile))
          .onChanged,
      isNull,
    );
    api.pending!.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<SettingsSwitchTile>(find.byType(SettingsSwitchTile)).value,
      isTrue,
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(api.calls, [true, false]);
    expect(
      tester.widget<SettingsSwitchTile>(find.byType(SettingsSwitchTile)).value,
      isFalse,
    );
  });
  testWidgets('failed native grant remains off and can be retried', (
    tester,
  ) async {
    api.fail = true;
    await mount(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SettingsSwitchTile>(find.byType(SettingsSwitchTile)).value,
      isFalse,
    );
    expect(
      tester
          .widget<SettingsSwitchTile>(find.byType(SettingsSwitchTile))
          .onChanged,
      isNotNull,
    );
    api.fail = false;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SettingsSwitchTile>(find.byType(SettingsSwitchTile)).value,
      isTrue,
    );
  });
}
