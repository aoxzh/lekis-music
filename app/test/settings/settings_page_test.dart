import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/enrich/enrich_providers.dart';
import 'package:lekis/src/features/settings/settings_page.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/settings/strings.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakeSources extends SourcesNotifier {
  _FakeSources(this.sources);
  final List<SourceConfigDto> sources;

  @override
  Future<List<SourceConfigDto>> build() async => sources;
}

class _FakePending extends EnrichPendingCountNotifier {
  @override
  int? build() => 0;
}

Widget _app({List<SourceConfigDto> sources = const []}) => ProviderScope(
  overrides: [
    sourcesProvider.overrideWith(() => _FakeSources(sources)),
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

SourceConfigDto _local() => const SourceConfigDto(
  kind: SourceKindDto.local,
  name: 'Music',
  addresses: ['/music'],
  rootPath: '',
  options: {},
  enabled: true,
);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('top level shows only the everyday groups, sources first', (
    tester,
  ) async {
    _size(tester, const Size(400, 1400));
    await tester.pumpWidget(_app(sources: [_local()]));
    await tester.pump();

    final sources = tester.getTopLeft(find.text(SettingsStrings.sources));
    final playback = tester.getTopLeft(find.text(SettingsStrings.playback));
    final advanced = tester.getTopLeft(find.text(SettingsStrings.advanced));
    expect(sources.dy, lessThan(playback.dy));
    expect(playback.dy, lessThan(advanced.dy));
    expect(find.text(SettingsStrings.sourcesCount(1)), findsOneWidget);

    // 进阶项不在首页。
    expect(find.text(SettingsStrings.outputMode), findsNothing);
    expect(find.text(SettingsStrings.scrobbling), findsNothing);
    expect(find.text(SettingsStrings.diagnosticLogs), findsNothing);
    expect(find.text(SettingsStrings.setupTitle), findsNothing);
  });

  testWidgets('no sources yet: a setup card leads the page', (tester) async {
    _size(tester, const Size(400, 1400));
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.text(SettingsStrings.setupTitle), findsOneWidget);
    expect(find.text(SettingsStrings.sourcesNone), findsOneWidget);
  });

  testWidgets('phone: a category row pushes its own page', (tester) async {
    _size(tester, const Size(400, 1400));
    await tester.pumpWidget(_app(sources: [_local()]));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('settings-category-about')));
    await tester.pumpAndSettle();

    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text(SettingsStrings.coreVersion), findsOneWidget);
    expect(find.text('9.9.9'), findsOneWidget);
  });

  testWidgets('desktop: list on the left, the chosen category on the right', (
    tester,
  ) async {
    _size(tester, const Size(1400, 1000));
    await tester.pumpWidget(_app(sources: [_local()]));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('settings-category-about')));
    await tester.pumpAndSettle();

    // 没有推入新页面：仍然是顶层，详情显示在右栏。
    expect(find.byType(BackButton), findsNothing);
    expect(find.text(SettingsStrings.coreVersion), findsOneWidget);
    final row = tester.getCenter(
      find.byKey(const ValueKey('settings-category-about')),
    );
    final detail = tester.getCenter(find.text(SettingsStrings.coreVersion));
    expect(detail.dx, greaterThan(row.dx));
  });
}
