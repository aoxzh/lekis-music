import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/features/playlists/playlist_strings.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _Playlists implements RustLibApi {
  final names = <String>[];
  final added = <(int, String)>[];

  @override
  Future<TrackDto> crateApiCoreGetTrack({required int trackId}) async =>
      TrackDto(
        id: trackId,
        uid: 'track',
        title: 'Night Walk',
        artists: const [],
        durationMs: BigInt.zero,
        genres: const [],
        loved: false,
        playCount: 0,
        isLocal: true,
      );

  @override
  Future<List<PlaylistDto>> crateApiCoreListPlaylists() async => [];

  @override
  Future<int> crateApiCoreCreatePlaylist({required String name}) async {
    names.add(name);
    return 3;
  }

  @override
  Future<String> crateApiCoreAddToPlaylist({
    required int playlistId,
    required String trackUid,
    String? beforeKey,
    String? afterKey,
  }) async {
    added.add((playlistId, trackUid));
    return 'position';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'new playlist uses the current sheet and handles Back, validation and submit',
    (tester) async {
      final api = _Playlists();
      RustLib.initMock(api: api);
      addTearDown(RustLib.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 740);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: lekisDarkTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAddToPlaylistSheet(
                    context,
                    trackId: 9,
                    trackTitle: 'Night Walk',
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(BottomSheet)).height, lessThan(370));
      final picker = ModalRoute.of(
        tester.element(find.text(PlaylistStrings.newShort)),
      );
      Future<void> create() async {
        await tester.tap(find.text(PlaylistStrings.newShort));
        await tester.pumpAndSettle();
        expect(
          ModalRoute.of(tester.element(find.byType(TextField))),
          same(picker),
        );
      }

      await create();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(PlaylistStrings.newShort), findsOneWidget);
      await create();
      await tester.tap(find.text(PlaylistStrings.createAndAdd));
      await tester.pumpAndSettle();
      expect(find.text(PlaylistStrings.nameEmpty), findsOneWidget);
      await tester.enterText(find.byType(TextField), '  Night  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(api.names, ['Night']);
      expect(api.added, [(3, 'track')]);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
