import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/music_export_dialog.dart';
import 'package:lekis/src/rust/api/music_export.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:material_ui/material_ui.dart';

class _Picker extends FilePickerPlatform {
  _Picker(this.folder);
  final Uri folder;

  @override
  Future<Uri?> pickDirectory({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => folder;
}

class _ExportApi implements RustLibApi {
  @override
  Future<List<MusicExportItemDto>> crateApiMusicExportExportMusic({
    int? trackId,
    int? albumId,
    required String directory,
    required String nameTemplate,
    required bool includeArtwork,
    required bool includeLyrics,
  }) async {
    expect(trackId, isNull);
    expect(albumId, 12);
    // `exportToDestination` converts the URI with `toFilePath()`, which uses
    // backslashes on Windows; compare against the same platform form.
    expect(directory, Uri.directory('/music export/').toFilePath());
    expect(nameTemplate, '{track}-{title}');
    expect(includeArtwork, isTrue);
    expect(includeLyrics, isFalse);
    return [
      MusicExportItemDto(
        trackId: 1,
        title: 'First',
        outputPath: '$directory/01-First.flac',
      ),
      const MusicExportItemDto(
        trackId: 2,
        title: 'Second',
        error: 'File exists',
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> openDialog(WidgetTester tester, Uri folder) async {
  final original = FilePickerPlatform.instance;
  FilePickerPlatform.instance = _Picker(folder);
  addTearDown(() => FilePickerPlatform.instance = original);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showMusicExport(context, albumId: 12),
          child: const Text('Open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('选择目录…'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('accepts the Android document tree URI from the picker', (
    tester,
  ) async {
    final tree = Uri.parse(
      'content://com.android.externalstorage.documents/tree/primary%3AMusic',
    );
    await openDialog(tester, tree);
    expect(find.text(tree.toString()), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '导出'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('passes album options and shows each publication result', (
    tester,
  ) async {
    RustLib.initMock(api: _ExportApi());
    addTearDown(RustLib.dispose);
    await openDialog(tester, Uri.directory('/music export/'));
    await tester.enterText(find.byType(TextFormField), '{track}-{title}');
    await tester.tap(find.text('嵌入歌词'));
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();
    expect(find.text('已导出 1 / 2 首'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('File exists'), findsOneWidget);
  });
}
