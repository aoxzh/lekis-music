import 'dart:async';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/albums_view.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/scoped_library_view.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:material_ui/material_ui.dart';

const _album = AlbumDto(
  id: 7,
  title: 'Shared album',
  artistLine: '',
  trackCount: 1,
);

class _Idle extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState();
}

class _Fixture {
  final firstPage = Completer<List<AlbumDto>>();
  final details = <ScopedAlbumQuery>[];
  late final container = ProviderContainer.test(
    retry: (_, _) => null,
    overrides: [
      scopedAlbumPageProvider.overrideWith(
        (ref, query) =>
            (offset, limit) async =>
                offset == 0 ? await firstPage.future : const [],
      ),
      scopedAlbumTrackPageProvider.overrideWith(
        (ref, query) => (offset, limit) async {
          details.add(query);
          return [
            TrackRowDto(
              id: query.$1.kind == LibraryScopeKind.nas ? 2 : 1,
              title: '${query.$1.kind.name} recording',
              artistLine: '',
              durationMs: BigInt.from(60000),
              isLocal: true,
              loved: false,
            ),
          ];
        },
      ),
      albumArtworkProvider.overrideWith((ref, albumId) async => null),
      playbackProvider.overrideWith(_Idle.new),
      downloadStateProvider.overrideWith((ref, id) => null),
      downloadProgressProvider.overrideWith((ref, id) => null),
    ],
  );

  Future<void> mount(WidgetTester tester, {required double width}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisLightTheme(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ScopedLibraryView(
                scope: ref.watch(librarySourceProvider),
                segment: LibrarySegment.albums,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  final grid = find.byType(AlbumGrid);
  final card = find.byType(AlbumCard);
  final detail = find.byType(ScopedLibraryAlbumPage);

  testWidgets('wide album detail shares the grid and follows its source', (
    tester,
  ) async {
    final fixture = _Fixture();
    await fixture.mount(tester, width: 1280);
    await tester.pump(LekisMotion.skeletonDelay);
    await tester.pump();
    expect(find.byType(SkeletonAlbumCard), findsWidgets);
    fixture.firstPage.complete([_album]);
    await tester.pumpAndSettle();
    expect(tester.getSize(grid).width, 1280);
    expect(
      find.descendant(of: grid, matching: find.byType(Scrollbar)),
      findsWidgets,
    );
    expect(fixture.details, isEmpty);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(grid).right,
      lessThanOrEqualTo(tester.getRect(detail).left),
    );
    expect(tester.widget<AlbumCard>(card).selected, isTrue);
    expect(Navigator.of(tester.element(detail)).canPop(), isFalse);
    expect(find.text('local recording'), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(detail, findsNothing);
    expect(tester.getSize(grid).width, 1280);
    expect(tester.widget<AlbumCard>(card).selected, isFalse);
    await tester.tap(card);
    await tester.pumpAndSettle();
    fixture.container
        .read(librarySourceProvider.notifier)
        .set(const LibraryScope.nas());
    await tester.pumpAndSettle();
    expect(detail, findsNothing);
    expect(tester.widget<AlbumCard>(card).selected, isFalse);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('nas recording'), findsOneWidget);
    expect(find.text('local recording'), findsNothing);
    expect(fixture.details.last, (const LibraryScope.nas(), _album.id));
  });

  testWidgets('compact album opens a route and Back restores the grid', (
    tester,
  ) async {
    final fixture = _Fixture()..firstPage.complete([_album]);
    await fixture.mount(tester, width: 390);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(grid, findsNothing);
    expect(find.text('local recording'), findsOneWidget);
    expect(Navigator.of(tester.element(detail)).canPop(), isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(grid, findsOneWidget);
    expect(detail, findsNothing);
  });

  testWidgets('separating hinge keeps both panes clear of the crease', (
    tester,
  ) async {
    const hinge = Rect.fromLTWH(380, 0, 24, 800);
    tester.view.displayFeatures = const [
      DisplayFeature(
        bounds: hinge,
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.unknown,
      ),
    ];
    final fixture = _Fixture()..firstPage.complete([_album]);
    await fixture.mount(tester, width: 800);
    await tester.pumpAndSettle();
    expect(tester.getRect(grid).right, hinge.left);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(tester.getRect(grid).right, hinge.left);
    expect(tester.getRect(detail).left, hinge.right);
    expect(Navigator.of(tester.element(detail)).canPop(), isFalse);
  });
}
