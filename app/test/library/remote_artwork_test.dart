import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/now_playing/now_playing_artwork.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const _cover = ArtworkDto(id: 1, hash: 'cached-video-cover', source: 'plugin');

class _Api implements RustLibApi {
  _Api(this.file);
  final String file;
  final requests = <int>[];
  final widths = <int>[];
  Completer<ArtworkDto?>? pending;
  ArtworkDto? result = _cover;
  bool smallBucketMissing = false;

  @override
  Future<ArtworkDto?> crateApiCoreArtwork({required int trackId}) async {
    requests.add(trackId);
    return pending == null ? result : pending!.future;
  }

  @override
  String crateApiCoreArtworkPath({required String hash, required int width}) {
    expect(hash, _cover.hash);
    widths.add(width);
    return smallBucketMissing && width < 1024 ? '$file.missing' : file;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.paused,
    trackId: 7,
    durationMs: 120000,
  );
}

TrackRowDto _row(int id, {bool local = false}) => TrackRowDto(
  id: id,
  title: 'Video $id',
  artistLine: 'Original uploader',
  durationMs: BigInt.from(120000),
  loved: false,
  isLocal: local,
);

void main() {
  late Directory temporary;
  late _Api api;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('lekis-cover-test-');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(const Color(0xFF1E4F80), BlendMode.src);
    canvas.drawRect(
      const Rect.fromLTWH(0, 64, 128, 64),
      Paint()..color = const Color(0xFFE3A44F),
    );
    final image = await recorder.endRecording().toImage(128, 128);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('${temporary.path}/cover.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
  tearDownAll(() async => temporary.delete(recursive: true));
  setUp(() {
    api = _Api('${temporary.path}/cover.png');
    RustLib.initMock(api: api);
  });
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    RustLib.dispose();
  });

  ProviderContainer container({
    Stream<CoreEventDto> events = const Stream.empty(),
  }) {
    final value = ProviderContainer.test(
      overrides: [
        coreEventSourceProvider.overrideWithValue(events),
        playbackProvider.overrideWith(_Playback.new),
        downloadStateProvider.overrideWith((ref, id) => null),
        downloadProgressProvider.overrideWith((ref, id) => null),
        currentTrackProvider.overrideWith(
          (ref) async => TrackDto(
            id: 7,
            uid: 'video-7',
            title: 'Video 7',
            artists: ['Original uploader'],
            durationMs: BigInt.from(120000),
            genres: [],
            loved: false,
            playCount: 0,
            isLocal: false,
          ),
        ),
      ],
    );
    addTearDown(value.dispose);
    return value;
  }

  Future<void> mount(
    WidgetTester tester,
    ProviderContainer value,
    Widget child,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: value,
        child: MaterialApp(
          theme: lekisLightTheme(),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> decodeImages(WidgetTester tester) async {
    // File reading, codec creation and frame decoding each cross real engine
    // futures. Alternate real event-loop turns and fake-clock pumps until the
    // rendered images are ready, rather than awaiting a fake-zone image stream.
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
      final images = tester.widgetList<RawImage>(find.byType(RawImage));
      if (images.isNotEmpty && images.every((image) => image.image != null)) {
        return;
      }
    }
  }

  testWidgets(
    'remote row resolves cover without an artwork ID; local row skips',
    (tester) async {
      final value = container();
      api.pending = Completer<ArtworkDto?>();
      await mount(
        tester,
        value,
        Column(
          children: [
            TrackTile(track: _row(7), onTap: () {}),
            TrackTile(track: _row(8, local: true), onTap: () {}),
          ],
        ),
      );
      expect(api.requests, [7]);
      expect(find.byType(ArtworkPlaceholder), findsNWidgets(2));
      api.pending!.complete(_cover);
      await tester.pumpAndSettle();
      await decodeImages(tester);
      expect(api.widths, contains(128));
      final decoded = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((image) => image.image != null);
      expect(decoded, isNotEmpty);
      expect(find.byType(ArtworkPlaceholder), findsOneWidget);
      expect(
        tester
            .widgetList<Image>(find.byType(Image))
            .every((image) => image.image is! NetworkImage),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'row, mini artwork and full artwork share the core cache lookup',
    (tester) async {
      final value = container();
      await mount(
        tester,
        value,
        Column(
          children: [
            TrackTile(track: _row(7), onTap: () {}),
            const SizedBox.square(dimension: 72, child: CurrentArtwork()),
            const SizedBox.square(dimension: 240, child: NowPlayingArtwork()),
          ],
        ),
      );
      await decodeImages(tester);
      expect(api.requests, [7]);
      expect(api.widths, containsAll([128, 256]));
      final decoded = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((image) => image.image != null);
      expect(decoded.length, greaterThanOrEqualTo(3));
      expect(find.byType(ArtworkPlaceholder), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing small bucket uses the cached large image, not a network URL',
    (tester) async {
      final value = container();
      api.smallBucketMissing = true;
      await mount(
        tester,
        value,
        const SizedBox.square(dimension: 48, child: TrackArtwork(trackId: 7)),
      );
      await decodeImages(tester);
      expect(api.widths, containsAll([128, 1024]));
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'no available remote image keeps the placeholder without repeated requests',
    (tester) async {
      final value = container();
      api.result = null;
      await mount(tester, value, TrackTile(track: _row(7), onTap: () {}));
      await tester.pump(const Duration(seconds: 3));
      expect(api.requests, [7]);
      expect(api.widths, isEmpty);
      expect(find.byType(ArtworkPlaceholder), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'catalog change refreshes a cached null for both row and current artwork',
    () async {
      final events = StreamController<CoreEventDto>();
      addTearDown(events.close);
      final value = container(events: events.stream);
      api.result = null;
      final row = value.listen(trackArtworkProvider(7), (_, _) {});
      addTearDown(row.close);
      expect(await value.read(currentArtworkProvider.future), isNull);
      expect(api.requests, [7]);
      api.result = _cover;
      events.add(
        const CoreEventDto.libraryChanged(scope: LibraryScopeDto.catalog),
      );
      await Future<void>.delayed(Duration.zero);
      expect(await value.read(currentArtworkProvider.future), _cover);
      expect(value.read(trackArtworkProvider(7)).value, _cover);
      expect(api.requests, [7, 7]);
    },
  );
}
