import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/plugins/plugin_format.dart';
import 'package:lekis/src/features/plugins/plugins_page.dart';
import 'package:lekis/src/features/plugins/plugins_providers.dart';
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
  error: error,
  directory: id,
  author: 'Lekis',
  homepage: null,
  permissions: const PluginPermissionsDto(
    network: ['lrclib.net'],
    process: [],
    requestHeaderHosts: [],
    webSignIn: false,
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

Widget _page(List<PluginInfoDto> plugins) => ProviderScope(
  overrides: [
    pluginListProvider.overrideWith(() => _FakePluginListNotifier(plugins)),
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
  });

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
