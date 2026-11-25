import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/mini_mode/mini_cover_backdrop.dart';
import 'package:lekis/src/features/mini_mode/mini_mode_controller.dart';
import 'package:lekis/src/features/mini_mode/mini_player_window.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/sleep_timer.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _MiniMode extends MiniModeController {
  @override
  bool build() => true;

  @override
  Future<void> enter() async => state = true;

  @override
  Future<void> exit() async => state = false;
}

class _Window implements MiniWindowGateway {
  String? saved;
  Completer<String?>? readGate;
  Completer<void>? writeGate;
  final writes = <String>[];
  int drags = 0;

  @override
  Future<String?> getSetting(String key) async => readGate?.future ?? saved;

  @override
  Future<void> setSetting(String key, String value) async {
    writes.add(value);
    await writeGate?.future;
    saved = value;
  }

  @override
  void startDragging() => drags++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    trackId: 1,
    state: PlaybackStateDto.playing,
    durationMs: 180000,
    queueIndex: 1,
    queueLength: 3,
  );
}

class _Position extends PositionController {
  @override
  int build() => 76000;
}

class _Actions extends PlayerActions {
  _Actions(super.ref);
  final calls = <Object>[];
  @override
  void playPause() => calls.add('pause');
  @override
  void next() => calls.add('next');
  @override
  void seek(int positionMs) => calls.add(positionMs);
  @override
  void setVolume(double volume) => calls.add(volume);
}

class _ArtworkApi implements RustLibApi {
  _ArtworkApi(this.path);
  final String path;
  @override
  String crateApiCoreArtworkPath({required String hash, required int width}) =>
      path;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _paintTestCover(File file) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFEDAB88), BlendMode.src);
  canvas.drawCircle(
    const Offset(82, 89),
    39,
    Paint()..color = const Color(0xFFFFE5AB),
  );
  for (var ridge = 0; ridge < 4; ridge++) {
    final base = 154.0 + ridge * 24;
    final path = Path()
      ..moveTo(0, base)
      ..cubicTo(60, base - 76 + ridge * 11, 138, base + 40, 256, base - 63)
      ..lineTo(256, 256)
      ..lineTo(0, 256)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = const [
          Color(0xFFB26D69),
          Color(0xFF965C68),
          Color(0xFF655369),
          Color(0xFF353F58),
        ][ridge],
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(256, 256);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
}

void main() {
  late Directory temp;
  final boundary = GlobalKey();
  late _Actions actions;
  final toggle = find.byKey(MiniPlayerView.coverToggleKey);
  final capture = Platform.environment['LEKIS_UI_CAPTURE_DIR'];
  final font = Platform.environment['LEKIS_UI_FONT'];

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('mini-cover-');
    await _paintTestCover(File('${temp.path}/cover.png'));
    for (final (family, path) in [
      ('Roboto', font),
      ('MaterialIcons', Platform.environment['LEKIS_UI_ICONS']),
    ]) {
      if (path == null) continue;
      final bytes = ByteData.sublistView(await File(path).readAsBytes());
      await (FontLoader(family)..addFont(Future.value(bytes))).load();
    }
  });
  tearDownAll(() => temp.delete(recursive: true));
  setUp(() => RustLib.initMock(api: _ArtworkApi('${temp.path}/cover.png')));
  tearDown(RustLib.dispose);

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    Size size = kMiniWindowSize,
    bool reduce = false,
    bool disable = false,
    bool dark = true,
    bool artwork = false,
    _Window? window,
  }) async {
    UiProfile.debugOverride = UiProfile.desktop;
    addTearDown(() => UiProfile.debugOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final container = ProviderContainer.test(
      overrides: [
        miniModeProvider.overrideWith(_MiniMode.new),
        miniWindowGatewayProvider.overrideWithValue(window ?? _Window()),
        playbackProvider.overrideWith(_Playback.new),
        positionProvider.overrideWith(_Position.new),
        playerActionsProvider.overrideWith((ref) => actions = _Actions(ref)),
        currentArtworkProvider.overrideWith(
          (ref) async => artwork
              ? const ArtworkDto(id: 1, hash: 'sunset', source: 'test')
              : null,
        ),
        currentTrackProvider.overrideWith(
          (ref) async => TrackDto(
            id: 1,
            uid: 'coast',
            title: 'After the Tide',
            artists: ['North Shore'],
            durationMs: BigInt.from(180000),
            genres: [],
            loved: false,
            playCount: 0,
            isLocal: true,
          ),
        ),
      ],
    );
    var theme = dark ? lekisDarkTheme() : lekisLightTheme();
    if (font != null) {
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
      );
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: LekisLocale(
          locale: const Locale('en'),
          child: MaterialApp(
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(reduceMotion: reduce, disableAnimations: disable),
              child: RepaintBoundary(
                key: boundary,
                child: MiniModeHost(child: child!),
              ),
            ),
            home: const Scaffold(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    final raw = find.byType(RawImage);
    for (
      var attempt = 0;
      attempt < 40 && tester.widget<RawImage>(raw).image == null;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
    }
    expect(tester.widget<RawImage>(raw).image, isNotNull);
    if (capture == null) return;
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(capture).create(recursive: true);
      await File('$capture/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final dark in [true, false]) {
    testWidgets(
      'file-backed artwork expands and returns (${dark ? "dark" : "light"})',
      (tester) async {
        final container = await mount(tester, artwork: true, dark: dark);
        final art = find.byType(Image);
        final square = tester.getSize(art);
        if (dark) await snapshot(tester, 'square-dark');
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.getSize(art).width, greaterThan(square.width * 1.5));
        expect(find.byTooltip('Show square cover'), findsOneWidget);
        await snapshot(tester, dark ? 'panorama-dark' : 'panorama-light');
        await tester.tap(find.byKey(MiniPlayerView.expandKey));
        await tester.pumpAndSettle();
        expect(find.byType(MiniPlayerView), findsNothing);
        await container.read(miniModeProvider.notifier).enter();
        await tester.pumpAndSettle();
        expect(find.byTooltip('Show square cover'), findsOneWidget);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.getSize(art), square);
      },
    );
  }

  testWidgets(
    'late reads and slow writes preserve the last choice across sessions',
    (tester) async {
      final window = _Window()
        ..readGate = Completer<String?>()
        ..writeGate = Completer<void>();
      await mount(tester, window: window);
      await tester.tap(toggle);
      await tester.pump();
      window.readGate!.complete('square');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Show square cover'), findsOneWidget);
      await tester.tap(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();
      expect(window.writes, ['panorama']);
      window.writeGate!.complete();
      await tester.pumpAndSettle();
      expect(window.writes, ['panorama', 'square', 'panorama']);
      window.readGate = null;
      await tester.pumpWidget(const SizedBox());
      await mount(tester, window: window);
      expect(find.byTooltip('Show square cover'), findsOneWidget);
      await tester.dragFrom(const Offset(50, 20), const Offset(48, 0));
      expect(window.drags, 1);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(window.saved, 'square');
    },
  );

  testWidgets(
    'panorama opens the timer and keeps seeking separate from window dragging',
    (tester) async {
      final window = _Window()..saved = 'panorama';
      final container = await mount(tester, window: window);
      await tester.tap(find.byKey(const ValueKey('mini-player.sleep-timer')));
      await tester.pumpAndSettle();
      final item = find.text('End of Track');
      await tester.ensureVisible(item);
      await tester.pumpAndSettle();
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(
        container.read(sleepTimerProvider).kind,
        SleepTimerKind.endOfTrack,
      );
      await tester.drag(find.byType(ThinProgressBar), const Offset(75, 0));
      expect(actions.calls.single, greaterThan(90000));
      expect(window.drags, 0);
    },
  );

  for (final disable in [false, true]) {
    testWidgets(
      'keyboard, compact controls and reduced motion (disable=$disable)',
      (tester) async {
        await mount(
          tester,
          size: const Size(200, 72),
          reduce: !disable,
          disable: disable,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        expect(actions.calls, ['pause']);
        for (
          var step = 0;
          step < 8 && find.byTooltip('Show square cover').evaluate().isEmpty;
          step++
        ) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          if (Focus.of(tester.element(find.byIcon(Icons.panorama_outlined)))
              .hasFocus) {
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pump();
          }
        }
        expect(find.byTooltip('Show square cover'), findsOneWidget);
        final geometry = tester.widget<AnimatedPositioned>(
          find.descendant(
            of: find.byType(MiniCoverBackdrop),
            matching: find.byType(AnimatedPositioned),
          ),
        );
        expect(geometry.duration, Duration.zero);
        await tester.tap(find.byIcon(Icons.skip_next_rounded));
        await tester.tapAt(tester.getCenter(find.byType(ThinProgressBar)));
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(5, 5),
            scrollDelta: Offset(0, 10),
          ),
        );
        expect(actions.calls, ['pause', 'next', 90000, isA<double>()]);
        await tester.tap(find.byKey(const ValueKey('mini-player.sleep-timer')));
        await tester.pumpAndSettle();
        expect(find.text('End of Track'), findsWidgets);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('End of Track'), findsNothing);
        await tester.tap(toggle);
        await tester.pump();
        expect(find.byTooltip('Show panoramic cover'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
