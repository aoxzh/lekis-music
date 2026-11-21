import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/features/sync/sync_providers.dart';
import 'package:lekis/src/features/sync/sync_settings_section.dart';
import 'package:lekis/src/features/sync/sync_strings.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakeSyncGateway implements SyncGateway {
  final Map<String, String> settings = {};
  final List<int> syncedSources = [];
  SyncReportDto report = SyncReportDto(
    pushed: BigInt.from(3),
    pulled: BigInt.from(5),
    applied: BigInt.from(2),
  );

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async =>
      settings[key] = value;

  @override
  Future<SyncReportDto> syncNow(int sourceId) async {
    syncedSources.add(sourceId);
    return report;
  }
}

class _FakeSources extends SourcesNotifier {
  _FakeSources(this.items);
  final List<SourceConfigDto> items;

  @override
  Future<List<SourceConfigDto>> build() async => items;
}

void main() {
  testWidgets('sync settings pick a filesystem source and trigger syncNow', (
    tester,
  ) async {
    final gw = _FakeSyncGateway()..settings[SyncSettingKeys.sourceId] = '42';
    final sources = [
      const SourceConfigDto(
        id: 42,
        kind: SourceKindDto.smb,
        name: '家庭 NAS',
        addresses: ['smb://nas/music'],
        rootPath: '',
        options: {},
        enabled: true,
      ),
      const SourceConfigDto(
        id: 99,
        kind: SourceKindDto.jellyfin,
        name: 'Jellyfin',
        addresses: ['http://nas:8096'],
        rootPath: '',
        options: {},
        enabled: true,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreEventSourceProvider.overrideWithValue(const Stream.empty()),
          syncGatewayProvider.overrideWithValue(gw),
          sourcesProvider.overrideWith(() => _FakeSources(sources)),
        ],
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(body: ListView(children: buildSyncSettingsSections())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('家庭 NAS'), findsOneWidget);
    // Non-filesystem media servers cannot act as the NAS folder sync channel.
    expect(find.text('Jellyfin'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('sync.now-button')));
    await tester.pumpAndSettle();

    expect(gw.syncedSources, [42]);
    expect(find.text(SyncStrings.report(3, 5, 2)), findsOneWidget);
    expect(gw.settings[SyncSettingKeys.lastSummary], contains('推送 3'));
  });
}
