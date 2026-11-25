import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/plugins/plugin_format.dart';
import 'package:lekis/src/features/plugins/plugin_registry.dart';
import 'package:lekis/src/features/plugins/plugins_page.dart';
import 'package:lekis/src/features/plugins/plugins_providers.dart';
import 'package:lekis/src/features/plugins/strings.dart';
import 'package:lekis/src/features/settings/settings_page.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

PluginInfoDto _plugin({
  String id = 'dev.lekis.test.lyrics',
  String name = '测试歌词插件',
  bool enabled = true,
  String? error,
}) => PluginInfoDto(
  id: id,
  name: name,
  version: '1.2.3',
  apiVersion: '1.0',
  runtime: 'js',
  kinds: const ['lyrics'],
  entry: 'index.js',
  enabled: enabled,
  nativeAndroidGranted: false,
  error: error,
  directory: id,
  author: 'Lekis',
  homepage: null,
  permissions: const PluginPermissionsDto(
    network: ['lrclib.net'],
    process: [],
    requestHeaderHosts: [],
    webSignIn: false,
    nativeAndroid: false,
    storageKb: 2048,
  ),
  settings: const [],
);

class _FakePluginListNotifier extends PluginListNotifier {
  _FakePluginListNotifier(this.plugins);

  final List<PluginInfoDto> plugins;

  @override
  Future<List<PluginInfoDto>> build() async => plugins;
}

Widget _page(
  List<PluginInfoDto> plugins, {
  Future<List<RegistryPlugin>> Function()? catalog,
}) => ProviderScope(
  overrides: [
    pluginListProvider.overrideWith(() => _FakePluginListNotifier(plugins)),
    if (catalog != null) pluginRegistryProvider.overrideWith((_) => catalog()),
  ],
  child: MaterialApp(theme: lekisLightTheme(), home: const PluginsPage()),
);

void main() {
  test('kind and permission summaries are readable', () {
    expect(pluginKindLabel('lyrics'), '歌词');
    expect(pluginKindLabel('playlist_importer'), '歌单导入');
    expect(pluginKindsLabel(const ['lyrics', 'artwork']), '歌词 · 封面');
    expect(pluginRuntimeLabel('js'), 'JavaScript');

    final plugin = _plugin();
    expect(
      pluginPermissionSummary(plugin.permissions),
      '网络：lrclib.net · 存储 2 MB',
    );
    expect(pluginSummaryLine(plugin), 'v1.2.3 · 歌词');
  });

  test('provider exposes the loaded list', () async {
    final plugin = _plugin();
    final container = ProviderContainer.test(
      overrides: [
        pluginListProvider.overrideWith(
          () => _FakePluginListNotifier([plugin]),
        ),
      ],
    );

    final list = await container.read(pluginListProvider.future);
    expect(list, hasLength(1));
    expect(list.single.id, 'dev.lekis.test.lyrics');
    expect(list.single.enabled, isTrue);
  });

  testWidgets('plugins page shows the installed list state', (tester) async {
    await tester.pumpWidget(_page([_plugin()]));
    await tester.pumpAndSettle();

    expect(find.text('测试歌词插件'), findsOneWidget);
    expect(find.text('v1.2.3 · 歌词'), findsOneWidget);
    expect(find.text('dev.lekis.test.lyrics'), findsOneWidget);
    expect(find.text('网络：lrclib.net · 存储 2 MB'), findsOneWidget);
    final summary = tester.widget<Text>(find.text('网络：lrclib.net · 存储 2 MB'));
    expect(summary.maxLines, 2);
    expect(summary.overflow, TextOverflow.ellipsis);
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('plugins page surfaces manifest errors', (tester) async {
    final broken = _plugin(
      id: 'broken-plugin',
      name: 'broken-plugin',
      enabled: false,
      error: 'invalid plugin.json: missing field `version`',
    );
    await tester.pumpWidget(_page([broken]));
    await tester.pumpAndSettle();

    expect(find.text('清单错误'), findsOneWidget);
    expect(find.textContaining('missing field'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
  });

  testWidgets('plugins page shows the empty state', (tester) async {
    await tester.pumpWidget(_page(const []));
    await tester.pumpAndSettle();

    expect(find.text('还没有安装插件'), findsOneWidget);
    expect(find.text('从 .zip 安装'), findsOneWidget);
    expect(find.text(PluginStrings.providerNotice), findsOneWidget);
  });

  testWidgets(
    'catalog loads on demand, retries and confirms on a narrow screen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.reset);
      final first = Completer<List<RegistryPlugin>>();
      final installed = _plugin();
      var reads = 0;
      final package = Uri.parse('https://example.test/packages/source.zip');
      RegistryPlugin entry(String id, String name) => RegistryPlugin(
        id: id,
        name: name,
        description: '插件说明',
        version: '1.2.3',
        package: package,
        sha256: 'a' * 64,
      );
      await tester.pumpWidget(
        _page(
          [installed],
          catalog: () async {
            reads++;
            if (reads == 1) return first.future;
            return [entry(installed.id, installed.name), entry('new', '新插件')];
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 0);
      expect(find.text(PluginStrings.providerNotice), findsOneWidget);
      await tester.tap(find.text(PluginStrings.browse));
      await tester.pump();
      expect(reads, 1);
      expect(find.text(PluginStrings.catalogLoading), findsOneWidget);
      first.completeError(const FormatException('test catalog'));
      await tester.pumpAndSettle();
      expect(find.textContaining(PluginStrings.catalogFailed), findsOneWidget);
      await tester.tap(find.byTooltip(PluginStrings.retry));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text(PluginStrings.installed), findsOneWidget);
      final install = find.widgetWithText(
        OutlinedButton,
        PluginStrings.downloadInstall,
      );
      expect(install, findsOneWidget);
      await tester.ensureVisible(install);
      await tester.tap(install);
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.text(PluginStrings.providerNotice),
        ),
        findsOneWidget,
      );
      expect(find.text(package.toString()), findsOneWidget);
      await tester.tap(find.text(PluginStrings.cancel));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(install, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'link import accepts HTTPS and cancellation keeps the list empty',
    (tester) async {
      await tester.pumpWidget(_page(const []));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从链接安装'));
      await tester.pumpAndSettle();
      final submit = find.widgetWithText(FilledButton, '安装插件');
      for (final invalid in [
        'file:///tmp/package.zip',
        'http://example.org/p.zip',
      ]) {
        await tester.enterText(find.byType(TextField), invalid);
        await tester.pump();
        expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      }
      await tester.enterText(
        find.byType(TextField),
        'https://example.org/p.zip',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('还没有安装插件'), findsOneWidget);
    },
  );

  testWidgets('settings tile shows the installed count', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pluginListProvider.overrideWith(
            () => _FakePluginListNotifier([_plugin()]),
          ),
        ],
        child: MaterialApp(
          theme: lekisLightTheme(),
          home: const Scaffold(body: PluginsSettingsTile()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('插件'), findsOneWidget);
    expect(find.text('已安装 1 个插件'), findsOneWidget);
  });
}
