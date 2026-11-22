// Desktop mini player mode: window geometry, persistence and the view.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/mini_mode/mini_mode_controller.dart';
import 'package:lekis/src/features/mini_mode/mini_player_window.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakeGateway implements MiniWindowGateway {
  _FakeGateway({this.stored});

  String? stored;
  Rect bounds = const Rect.fromLTWH(100, 100, 1280, 820);
  final calls = <String>[];
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
  FullWindowSnapshot capture() => _full;

  @override
  List<Rect> workAreas() => const [Rect.fromLTWH(0, 0, 1920, 1040)];

  @override
  Future<void> applyMini(Rect b) async {
    calls.add('mini $b');
    bounds = b;
  }

  @override
  Future<void> restore(FullWindowSnapshot snapshot) async {
    calls.add('restore maximized=${snapshot.maximized}');
    bounds = snapshot.bounds;
  }

  @override
  Rect? currentBounds() => bounds;

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
  });

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
}
