import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/now_playing/alternate_source_sheet.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/alternate_source.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

final _track = TrackDto(
  id: 7,
  uid: 'original',
  title: 'Original',
  artists: const ['Singer'],
  durationMs: BigInt.from(40000),
  genres: const [],
  loved: false,
  playCount: 0,
  isLocal: false,
);
final _candidate = AlternateSourceDto(
  pluginId: 'source',
  externalId: 'alternate',
  title: 'Live recording',
  artist: 'Singer',
  durationMs: BigInt.from(41000),
);
const _plugin = PluginInfoDto(
  id: 'source',
  name: 'Online source',
  version: '1',
  apiVersion: '1',
  runtime: 'js',
  kinds: ['source'],
  enabled: true,
  nativeAndroidGranted: false,
  directory: 'source',
  permissions: PluginPermissionsDto(
    network: [],
    process: [],
    requestHeaderHosts: [],
    webSignIn: false,
    nativeAndroid: false,
    storageKb: 0,
  ),
  settings: [],
);

class _Playback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(trackId: 7);
}

class _Api implements RustLibApi {
  final finishes = <(int, bool)>[];
  final queries = <String>[];
  AlternateSourceDto? saved;
  Completer<int>? opening;
  @override
  Future<List<PluginInfoDto>> crateApiCorePlugins() async => [_plugin];
  @override
  Future<List<AlternateSourceDto>>
  crateApiAlternateSourceSearchAlternateSources({
    required int trackId,
    required String pluginId,
    required String query,
  }) async {
    expect((trackId, pluginId), (7, 'source'));
    queries.add(query);
    return [_candidate];
  }

  @override
  Future<AlternateSourceDto?> crateApiAlternateSourceGetAlternateSource({
    required int trackId,
  }) async => saved;
  @override
  Future<int> crateApiAlternateSourcePreviewAlternateSource({
    required int trackId,
    required AlternateSourceDto candidate,
  }) async {
    expect((trackId, candidate), (7, _candidate));
    return opening?.future ?? Future.value(91);
  }

  @override
  Future<void> crateApiAlternateSourceFinishAlternateSourcePreview({
    required int previewId,
    required bool remember,
  }) async {
    finishes.add((previewId, remember));
    if (remember) saved = _candidate;
  }

  @override
  Future<void> crateApiAlternateSourceResetAlternateSource({
    required int trackId,
  }) async {
    expect(trackId, 7);
    saved = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Api api;
  setUp(() {
    api = _Api();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playbackProvider.overrideWith(_Playback.new)],
        child: MaterialApp(
          theme: lekisLightTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAlternateSourceSheet(context, _track),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await open(tester);
  }

  testWidgets(
    'search, audition, cancel, remember and reset the original track',
    (tester) async {
      await mount(tester);
      expect(api.queries, ['Original']);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '记住此音源'))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), 'Singer');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(api.queries, ['Original', 'Singer']);
      await tester.tap(find.text('试听'));
      await tester.pumpAndSettle();
      expect(find.text('试听中'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.finishes, [(91, false)]);
      await open(tester);
      await tester.tap(find.text('试听'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记住此音源'));
      await tester.pumpAndSettle();
      expect(api.finishes, [(91, false), (91, true)]);
      await open(tester);
      expect(find.text('已记住的音源'), findsOneWidget);
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();
      expect(api.saved, isNull);
    },
  );

  testWidgets(
    'closing the sheet during a pending audition releases the late token',
    (tester) async {
      api.opening = Completer<int>();
      await mount(tester);
      await tester.tap(find.text('试听'));
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('手动换源'), findsNothing);
      api.opening!.complete(103);
      await tester.pump();
      expect(api.finishes, [(103, false)]);
    },
  );
}
