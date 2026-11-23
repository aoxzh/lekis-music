// Desktop mini player mode: window geometry, persistence and the view.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/connect/connect_active.dart';
import 'package:lekis/src/features/mini_mode/mini_mode_controller.dart';
import 'package:lekis/src/features/mini_mode/mini_player_window.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/mini_player.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakeGateway implements MiniWindowGateway {
  _FakeGateway({this.stored});

  String? stored;
  Rect bounds = const Rect.fromLTWH(100, 100, 1280, 820);
  final calls = <String>[];
  bool failRestore = false;
  FullWindowSnapshot snapshot = _full;
  Completer<void>? captureReady;
  FullWindowSnapshot? restored;
  void Function(Rect)? _onMoved;

  static const _full = FullWindowSnapshot(
    bounds: Rect.fromLTWH(100, 100, 1280, 820),
    maximized: true,
    alwaysOnTop: false,
    resizable: true,
    maximizable: true,
    titleBarHidden: false,
    minimumSize: Size(480, 400),
  );

  @override
  bool get isAvailable => true;

  @override
  Future<FullWindowSnapshot> capture() async {
    await captureReady?.future;
    return snapshot;
  }

  @override
  List<Rect> workAreas() => const [Rect.fromLTWH(0, 0, 1920, 1040)];

  @override
  Future<void> applyMini(Rect b) async {
    calls.add('mini $b');
    bounds = b;
  }

  @override
  Future<void> restore(FullWindowSnapshot snapshot) async {
    if (failRestore) throw StateError('temporary native restore failure');
    restored = snapshot;
    calls.add('restore maximized=${snapshot.maximized}');
    bounds = snapshot.bounds;
  }

  @override
  Rect? currentBounds() => bounds;

  @override
  void startDragging() => calls.add('drag');

  @override
  VoidCallback listenMoves(void Function(Rect bounds) onMoved) {
    _onMoved = onMoved;
    return () => _onMoved = null;
  }

  void move(Offset to) {
    bounds = to & bounds.size;
    _onMoved?.call(bounds);
  }

  @override
  Future<String?> getSetting(String key) async =>
      key == MiniModeSettingKeys.position ? stored : null;

  @override
  Future<void> setSetting(String key, String value) async {
    if (key == MiniModeSettingKeys.position) stored = value;
  }
}

class _FakePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.paused,
    trackId: 1,
    durationMs: 240000,
    queueLength: 3,
    queueIndex: 1,
    volume: 0.8,
  );
}

class _FakePosition extends PositionController {
  @override
  int build() => 60000;
}

class _SpyActions extends PlayerActions {
  _SpyActions(super.ref);
  final calls = <String>[];

  @override
  void playPause() => calls.add('playPause');
  @override
  void next() => calls.add('next');
  @override
  void previous() => calls.add('previous');
}

class _StatefulPage extends StatefulWidget {
  const _StatefulPage();

  @override
  State<_StatefulPage> createState() => _StatefulPageState();
}

class _StatefulPageState extends State<_StatefulPage> {
  int count = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () => setState(() => count++),
      child: Text('count=$count'),
    ),
  );
}

void main() {
  group('placeMiniWindow', () {
    const areas = [Rect.fromLTWH(0, 0, 1920, 1040)];
    const full = Rect.fromLTWH(100, 100, 1280, 820);

    test('defaults to the bottom-right of the work area', () {
      final r = placeMiniWindow(
        saved: null,
        fullBounds: full,
        workAreas: areas,
      );
      expect(r.size, kMiniWindowSize);
      expect(r.right, 1920 - 24);
      expect(r.bottom, 1040 - 24);
    });

    test('reuses a remembered position that is on screen', () {
      final r = placeMiniWindow(
        saved: const Offset(300, 200),
        fullBounds: full,
        workAreas: areas,
      );
      expect(r.topLeft, const Offset(300, 200));
    });

    test('ignores a position on a display that is gone', () {
      final r = placeMiniWindow(
        saved: const Offset(3000, 200),
        fullBounds: full,
        workAreas: areas,
      );
      expect(r.right, 1920 - 24);
    });

    test('position round-trips through storage', () {
      expect(
        parseMiniPosition(encodeMiniPosition(const Offset(-12, 40))),
        const Offset(-12, 40),
      );
      expect(parseMiniPosition('garbage'), isNull);
      expect(parseMiniPosition(null), isNull);
    });
  });

  group('MiniModeController', () {
    test(
      'enters at the remembered spot, saves moves, restores on exit',
      () async {
        final gateway = _FakeGateway(stored: '400,300');
        final container = ProviderContainer(
          overrides: [
            miniWindowGatewayProvider.overrideWithValue(gateway),
            miniModeSupportedProvider.overrideWithValue(true),
          ],
        );
        addTearDown(container.dispose);
        final mini = container.read(miniModeProvider.notifier);

        await mini.enter();
        expect(container.read(miniModeProvider), isTrue);
        expect(gateway.calls.single, contains('Rect.fromLTRB(400.0, 300.0'));

        gateway.move(const Offset(500, 320));
        await mini.exit();
        expect(container.read(miniModeProvider), isFalse);
        expect(gateway.calls.last, 'restore maximized=true');
        expect(gateway.stored, '500,320');

        // Next time it comes back where it was left.
        gateway.calls.clear();
        await mini.toggle();
        expect(gateway.calls.single, contains('Rect.fromLTRB(500.0, 320.0'));
      },
    );

    test('does nothing where mini mode is unsupported', () async {
      final gateway = _FakeGateway();
      final container = ProviderContainer(
        overrides: [
          miniWindowGatewayProvider.overrideWithValue(gateway),
          miniModeSupportedProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await container.read(miniModeProvider.notifier).enter();
      expect(container.read(miniModeProvider), isFalse);
      expect(gateway.calls, isEmpty);
    });

    test(
      'waits for normal window capture and restores fullscreen state',
      () async {
        final gateway = _FakeGateway()..captureReady = Completer<void>();
        gateway.snapshot = const FullWindowSnapshot(
          bounds: Rect.fromLTWH(100, 100, 800, 600),
          maximized: false,
          fullScreen: true,
          alwaysOnTop: false,
          resizable: true,
          maximizable: true,
          titleBarHidden: false,
          minimumSize: Size(480, 400),
        );
        final container = ProviderContainer(
          overrides: [
            miniWindowGatewayProvider.overrideWithValue(gateway),
            miniModeSupportedProvider.overrideWithValue(true),
          ],
        );
        addTearDown(container.dispose);
        final mini = container.read(miniModeProvider.notifier);
        final entering = mini.enter();
        await Future<void>.delayed(Duration.zero);
        expect(container.read(miniModeProvider), isFalse);
        expect(gateway.calls, isEmpty);
        gateway.captureReady!.complete();
        await entering;
        expect(container.read(miniModeProvider), isTrue);
        await mini.exit();
        expect(gateway.restored, same(gateway.snapshot));
        expect(gateway.restored!.fullScreen, isTrue);
      },
    );

    test(
      'keeps mini controls and snapshot when restore fails so exit can retry',
      () async {
        final gateway = _FakeGateway();
        final container = ProviderContainer(
          overrides: [
            miniWindowGatewayProvider.overrideWithValue(gateway),
            miniModeSupportedProvider.overrideWithValue(true),
          ],
        );
        addTearDown(container.dispose);
        final mini = container.read(miniModeProvider.notifier);
        await mini.enter();
        gateway.failRestore = true;
        await mini.exit();
        expect(container.read(miniModeProvider), isTrue);
        gateway.failRestore = false;
        await mini.exit();
        expect(container.read(miniModeProvider), isFalse);
        expect(gateway.restored, same(gateway.snapshot));
      },
    );
  });

  testWidgets(
    'default 800 dp mac window has a working compact-bar mini entry',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      UiProfile.debugOverride = UiProfile.desktop;
      addTearDown(() {
        tester.view.reset();
        UiProfile.debugOverride = null;
      });
      final gateway = _FakeGateway();
      final container = ProviderContainer(
        overrides: [
          coreEventSourceProvider.overrideWithValue(const Stream.empty()),
          miniWindowGatewayProvider.overrideWithValue(gateway),
          miniModeSupportedProvider.overrideWithValue(true),
          playbackProvider.overrideWith(_FakePlayback.new),
          positionProvider.overrideWith(_FakePosition.new),
          currentTrackProvider.overrideWith((ref) async => null),
          currentArtworkProvider.overrideWith((ref) async => null),
          hasConnectDevicesProvider.overrideWithValue(false),
          activeRemoteDeviceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: lekisDarkTheme(),
            builder: (context, child) => MiniModeHost(child: child!),
            home: const Scaffold(
              bottomNavigationBar: SizedBox(
                height: LekisSizes.miniPlayerHeight,
                child: MiniPlayerFace(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(MiniPlayerFace.miniModeKey), findsOneWidget);
      await tester.tap(find.byKey(MiniPlayerFace.miniModeKey));
      await tester.pumpAndSettle();
      expect(container.read(miniModeProvider), isTrue);
      expect(find.byType(MiniPlayerView), findsOneWidget);
      // The fake gateway does not own a real window; deliver its resize as
      // the native embedder does after applyMini.
      tester.view.physicalSize = kMiniWindowSize;
      await tester.pumpAndSettle();
      await tester.dragFrom(
        tester.getTopLeft(find.byType(MiniPlayerView)) + const Offset(160, 16),
        const Offset(40, 0),
      );
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('drag'));
      await tester.tap(find.byKey(MiniPlayerView.expandKey));
      await tester.pumpAndSettle();
      expect(container.read(miniModeProvider), isFalse);
      expect(find.byKey(MiniPlayerFace.miniModeKey), findsOneWidget);
    },
  );

  testWidgets('MiniModeHost swaps in the mini player and its controls drive '
      'playback', (tester) async {
    tester.view.physicalSize = kMiniWindowSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final gateway = _FakeGateway();
    late _SpyActions actions;
    final container = ProviderContainer(
      overrides: [
        coreEventSourceProvider.overrideWithValue(const Stream.empty()),
        miniWindowGatewayProvider.overrideWithValue(gateway),
        miniModeSupportedProvider.overrideWithValue(true),
        playbackProvider.overrideWith(_FakePlayback.new),
        positionProvider.overrideWith(_FakePosition.new),
        currentTrackProvider.overrideWith((ref) async => null),
        currentArtworkProvider.overrideWith((ref) async => null),
        playerActionsProvider.overrideWith((ref) => actions = _SpyActions(ref)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisDarkTheme(),
          builder: (context, child) => MiniModeHost(child: child!),
          home: const Scaffold(body: Text('full-ui')),
        ),
      ),
    );
    expect(find.text('full-ui'), findsOneWidget);
    expect(find.byType(MiniPlayerView), findsNothing);

    unawaited(container.read(miniModeProvider.notifier).enter());
    await tester.pumpAndSettle();
    expect(find.byType(MiniPlayerView), findsOneWidget);
    // The full UI is kept (offstage), not torn down.
    expect(find.text('full-ui', skipOffstage: false), findsOneWidget);

    for (final icon in const [
      Icons.skip_next_rounded,
      Icons.skip_previous_rounded,
      Icons.play_arrow_rounded,
    ]) {
      await tester.tap(find.byIcon(icon));
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(actions.calls, ['next', 'previous', 'playPause']);

    await tester.tap(find.byKey(MiniPlayerView.expandKey));
    await tester.pumpAndSettle();
    expect(container.read(miniModeProvider), isFalse);
    expect(find.byType(MiniPlayerView), findsNothing);
    expect(find.text('full-ui'), findsOneWidget);
  });

  testWidgets('mini mode preserves the Navigator, open route and page state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    final gateway = _FakeGateway();
    final container = ProviderContainer(
      overrides: [
        coreEventSourceProvider.overrideWithValue(const Stream.empty()),
        miniWindowGatewayProvider.overrideWithValue(gateway),
        miniModeSupportedProvider.overrideWithValue(true),
        playbackProvider.overrideWith(_FakePlayback.new),
        positionProvider.overrideWith(_FakePosition.new),
        currentTrackProvider.overrideWith((ref) async => null),
        currentArtworkProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          theme: lekisDarkTheme(),
          builder: (context, child) => MiniModeHost(child: child!),
          home: const _StatefulPage(),
        ),
      ),
    );
    await tester.tap(find.text('count=0'));
    await tester.pump();
    final originalNavigator = navigator.currentState;
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('open-route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(container.read(miniModeProvider.notifier).enter());
    await tester.pumpAndSettle();
    expect(navigator.currentState, same(originalNavigator));
    expect(find.text('open-route', skipOffstage: false), findsOneWidget);
    expect(find.text('count=1', skipOffstage: false), findsOneWidget);
    await container.read(miniModeProvider.notifier).exit();
    await tester.pumpAndSettle();
    expect(navigator.currentState, same(originalNavigator));
    expect(find.text('open-route'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('count=1'), findsOneWidget);
  });
}
