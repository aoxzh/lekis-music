import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lekis/src/features/search/spotify_catalog_page.dart';
import 'package:lekis/src/rust/api/core.dart';

void main() {
  testWidgets('saves a token, searches and opens an attributed result', (
    tester,
  ) async {
    String? saved;
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: SpotifyCatalogPage(
          allowPersistentToken: true,
          hasToken: () => false,
          saveToken: (value) async {
            saved = value;
          },
          openLink: (value) async {
            opened = value;
            return true;
          },
          search: (album, artist, market) async {
            expect((album, artist, market), ('Album', 'Artist', 'SG'));
            return [
              const SpotifyAlbumDto(
                id: '1',
                title: 'Album',
                artists: ['Artist'],
                spotifyUrl: 'https://open.spotify.com/album/1',
              ),
            ];
          },
        ),
      ),
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'secret-token');
    await tester.tap(find.text('安全保存'));
    await tester.pump();
    expect(saved, 'secret-token');
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, isEmpty);
    await tester.enterText(fields.at(1), 'Album');
    await tester.enterText(fields.at(2), 'Artist');
    await tester.ensureVisible(find.text('搜索专辑'));
    await tester.tap(find.text('搜索专辑'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is AssetImage),
      findsOneWidget,
    );
    expect(find.text('Artist'), findsWidgets);
    await tester.ensureVisible(find.text('Album').last);
    await tester.tap(find.text('Album').last);
    await tester.pump();
    expect(opened, 'https://open.spotify.com/album/1');
  });

  testWidgets('session-only token is never sent to persistent storage', (
    tester,
  ) async {
    var writes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SpotifyCatalogPage(
          allowPersistentToken: false,
          saveToken: (_) async {
            writes++;
          },
          search: (_, _, _) async => [],
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'temporary-secret');
    await tester.tap(find.text('用于本次查询'));
    await tester.pump();
    expect(writes, 0);
    expect(find.text('temporary-secret'), findsNothing);
    expect(find.text('删除令牌'), findsOneWidget);
  });

  testWidgets('Apple Music source uses a separate session token and link', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: SpotifyCatalogPage(
          allowPersistentToken: false,
          openLink: (url) async {
            opened = url;
            return true;
          },
          search: (_, _, _) async => [
            const SpotifyAlbumDto(
              id: '1',
              title: 'Apple album',
              artists: ['Artist'],
              spotifyUrl: 'https://music.apple.com/sg/album/test/1',
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Apple Music'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), 'developer-token');
    await tester.tap(find.text('用于本次查询'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'Album');
    await tester.enterText(find.byType(TextField).at(2), 'Artist');
    await tester.ensureVisible(find.text('搜索专辑'));
    await tester.tap(find.text('搜索专辑'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Apple album'));
    expect(find.text('Apple Music'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is AssetImage),
      findsNothing,
    );
    await tester.tap(find.text('Apple album'));
    await tester.pump();
    expect(opened, 'https://music.apple.com/sg/album/test/1');
  });
}
