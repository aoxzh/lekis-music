import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/track_sources_sheet.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakeUnifiedGateway implements UnifiedLibraryGateway {
  _FakeUnifiedGateway(this.entries);

  List<TrackSourceInfoDto> entries;
  final List<(int, int, int?, String?)> splitCalls = [];

  @override
  Future<List<TrackSourceInfoDto>> trackSources(int trackId) async => entries;

  @override
  Future<int> mergeTracks(int keepId, List<int> absorbIds) async =>
      absorbIds.length;

  @override
  Future<int> splitTrackSource({
    required int trackId,
    required int sourceId,
    int? fileId,
    String? externalId,
  }) async {
    splitCalls.add((trackId, sourceId, fileId, externalId));
    entries = [entries.first];
    return 999;
  }

  @override
  Future<bool> deleteDuplicateFile({
    required int sourceId,
    required String path,
    required bool deleteSourceFile,
  }) async => true;
}

void main() {
  testWidgets('TrackSourcesView shows preferred badge and splits a source', (
    tester,
  ) async {
    final gw = _FakeUnifiedGateway([
      TrackSourceInfoDto(
        sourceId: 1,
        sourceName: '本机音乐',
        sourceKind: SourceKindDto.local,
        fileId: 10,
        path: 'jay/晴天.flac',
        externalId: null,
        sizeBytes: BigInt.from(31457280),
        format: 'FLAC 24/96',
        qualityScore: 900,
        reachable: true,
        preferred: true,
      ),
      TrackSourceInfoDto(
        sourceId: 2,
        sourceName: '家庭 Jellyfin',
        sourceKind: SourceKindDto.jellyfin,
        fileId: null,
        path: '',
        externalId: 'jf-item-1',
        sizeBytes: BigInt.zero,
        format: null,
        qualityScore: 150,
        reachable: true,
        preferred: false,
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [unifiedLibraryGatewayProvider.overrideWithValue(gw)],
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: const Scaffold(
            body: TrackSourcesView(trackId: 7, trackTitle: '晴天'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本机音乐'), findsOneWidget);
    expect(find.text('家庭 Jellyfin'), findsOneWidget);
    expect(find.text(UnifiedStrings.preferred), findsOneWidget);
    expect(find.byKey(const ValueKey('track-source.split.1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('track-source.split.1')));
    await tester.pumpAndSettle();

    expect(gw.splitCalls, [(7, 2, null, 'jf-item-1')]);
    expect(find.text(UnifiedStrings.splitDone), findsOneWidget);
    // Only 1 source left -> split button disappears.
    expect(find.byKey(const ValueKey('track-source.split.0')), findsNothing);
  });
}
