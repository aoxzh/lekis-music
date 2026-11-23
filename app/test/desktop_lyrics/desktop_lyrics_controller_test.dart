import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_controller.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_settings_section.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/desktop_lyrics.dart' as bridge;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakeDesktopLyricsGateway implements DesktopLyricsGateway {
  _FakeDesktopLyricsGateway({
    this.supported = true,
    this.menuBarSupported = false,
  });

  final bool supported;
  final bool menuBarSupported;
  final Map<String, String> settings = {};
  final StreamController<bridge.DesktopLyricsEventDto> controller =
      StreamController<bridge.DesktopLyricsEventDto>.broadcast();
  bool visible = false;
  bool menuBarVisible = false;
  bool locked = false;
  bridge.DesktopLyricsStyleDto? lastStyle;
  String? lastPlacements;

  @override
  bool isSupported() => supported;

  @override
  bool isMenuBarSupported() => menuBarSupported;

  @override
  bool setMenuBarVisible(bool visible) =>
      menuBarVisible = menuBarSupported && visible;

  @override
  bool show() {
    if (!supported) return false;
    visible = true;
    return true;
  }

  @override
  void hide() => visible = false;

  @override
  void setLocked(bool value) => locked = value;

  @override
  void setStyle(bridge.DesktopLyricsStyleDto style) => lastStyle = style;

  @override
  void setLyrics(bridge.DesktopLyricsDocDto doc) {}

  @override
  void setClock(bridge.DesktopLyricsClockDto clock) {}

  @override
  void setPlacements(String json) => lastPlacements = json;

  @override
  Stream<bridge.DesktopLyricsEventDto> events() => controller.stream;

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async =>
      settings[key] = value;

  Future<void> dispose() => controller.close();
}

class _SlowDesktopLyricsGateway extends _FakeDesktopLyricsGateway {
  _SlowDesktopLyricsGateway() : super(menuBarSupported: true);
  final reads = <String, Completer<String?>>{};
  @override
  Future<String?> getSetting(String key) =>
      (reads[key] = Completer<String?>()).future;
  void finishReads({bool savedMenuBar = false}) {
    for (final entry in reads.entries) {
      entry.value.complete(
        entry.key == DesktopLyricsSettingKeys.menuBarVisible && savedMenuBar
            ? 'true'
            : null,
      );
    }
  }
}

class _FakeActions extends PlayerActions {
  _FakeActions(super.ref);

  int toggles = 0;
  int nexts = 0;
  int prevs = 0;

  @override
  void playPause() => toggles++;

  @override
  void next() => nexts++;

  @override
  void previous() => prevs++;
}

void main() {
  test('settings action waits for pending restore and keeps native state consistent', () async {
    final gw = _SlowDesktopLyricsGateway();
    final container = ProviderContainer(
      overrides: [desktopLyricsGatewayProvider.overrideWithValue(gw)],
    );
    addTearDown(() async {
      container.dispose();
      await gw.dispose();
    });
    final ctrl = container.read(desktopLyricsProvider.notifier);
    final boot = ctrl.bootstrap();
    final action = ctrl.setMenuBarVisible(true);
    expect(gw.menuBarVisible, isFalse);
    gw.finishReads();
    await Future.wait([boot, action]);
    expect(container.read(desktopLyricsProvider).menuBarVisible, isTrue);
    expect(gw.menuBarVisible, isTrue);
    expect(gw.settings[DesktopLyricsSettingKeys.menuBarVisible], 'true');
  });

  test(
    'native close during restore wins over saved menu bar visibility',
    () async {
      final gw = _SlowDesktopLyricsGateway();
      final container = ProviderContainer(
        overrides: [desktopLyricsGatewayProvider.overrideWithValue(gw)],
      );
      addTearDown(() async {
        container.dispose();
        await gw.dispose();
      });
      final boot = container.read(desktopLyricsProvider.notifier).bootstrap();
      gw.controller.add(const bridge.DesktopLyricsEventDto.menuBarClosed());
      await Future<void>.delayed(Duration.zero);
      gw.finishReads(savedMenuBar: true);
      await boot;
      expect(container.read(desktopLyricsProvider).menuBarVisible, isFalse);
      expect(gw.menuBarVisible, isFalse);
    },
  );

  test(
    'new track id never receives retained metadata from the previous track',
    () {
      final oldTrack = TrackDto(
        id: 1,
        uid: 'old',
        title: 'Previous song',
        artists: ['Previous artist'],
        durationMs: BigInt.zero,
        genres: [],
        loved: false,
        playCount: 0,
        isLocal: false,
      );
      final doc = buildDesktopLyricsDoc(
        trackId: 2,
        track: oldTrack,
        lyrics: null,
      );
      expect(doc.trackId, 2);
      expect(doc.title, isEmpty);
      expect(doc.artist, isEmpty);
      final current = buildDesktopLyricsDoc(
        trackId: 1,
        track: oldTrack,
        lyrics: null,
      );
      expect(current.title, 'Previous song');
    },
  );

  test(
    'menu bar restores independently and native menu changes persist',
    () async {
      final gw = _FakeDesktopLyricsGateway(menuBarSupported: true)
        ..settings[DesktopLyricsSettingKeys.menuBarVisible] = 'true';
      final container = ProviderContainer(
        overrides: [desktopLyricsGatewayProvider.overrideWithValue(gw)],
      );
      addTearDown(() async {
        container.dispose();
        await gw.dispose();
      });
      final ctrl = container.read(desktopLyricsProvider.notifier);
      await ctrl.bootstrap();
      expect(container.read(desktopLyricsProvider).menuBarVisible, isTrue);
      expect(gw.menuBarVisible, isTrue);
      expect(gw.visible, isFalse);
      expect(gw.lastStyle?.fontSize, 26);
      await ctrl.setVisible(true);
      await ctrl.setVisible(false);
      expect(gw.menuBarVisible, isTrue);
      gw.controller.add(
        const bridge.DesktopLyricsEventDto.visibilityChanged(visible: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(desktopLyricsProvider).visible, isTrue);
      expect(gw.settings[DesktopLyricsSettingKeys.visible], 'true');
      gw.controller.add(const bridge.DesktopLyricsEventDto.menuBarClosed());
      await Future<void>.delayed(Duration.zero);
      expect(container.read(desktopLyricsProvider).menuBarVisible, isFalse);
      expect(container.read(desktopLyricsProvider).visible, isTrue);
      expect(gw.settings[DesktopLyricsSettingKeys.menuBarVisible], 'false');
    },
  );

  test('menu bar toggle stays off on unsupported platforms', () async {
    final gw = _FakeDesktopLyricsGateway();
    final container = ProviderContainer(
      overrides: [desktopLyricsGatewayProvider.overrideWithValue(gw)],
    );
    addTearDown(() async {
      container.dispose();
      await gw.dispose();
    });
    await container
        .read(desktopLyricsProvider.notifier)
        .setMenuBarVisible(true);
    expect(gw.menuBarVisible, isFalse);
    expect(container.read(desktopLyricsProvider).menuBarVisible, isFalse);
    expect(
      gw.settings.containsKey(DesktopLyricsSettingKeys.menuBarVisible),
      isFalse,
    );
  });

  testWidgets('macOS settings expose separate menu bar and desktop switches', (
    tester,
  ) async {
    final gw = _FakeDesktopLyricsGateway(menuBarSupported: true);
    addTearDown(gw.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopLyricsGatewayProvider.overrideWithValue(gw)],
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: const Scaffold(
            body: SingleChildScrollView(child: DesktopLyricsSettingsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('desktop-lyrics.menu-bar-visible')),
    );
    await tester.pumpAndSettle();
    expect(gw.menuBarVisible, isTrue);
    expect(gw.visible, isFalse);
    expect(gw.settings[DesktopLyricsSettingKeys.menuBarVisible], 'true');
    final opacity = find.byKey(const ValueKey('desktop-lyrics.opacity'));
    await tester.ensureVisible(opacity);
    await tester.drag(opacity, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(gw.lastStyle?.opacity, lessThan(1));
    expect(
      double.tryParse(gw.settings[DesktopLyricsSettingKeys.opacity] ?? ''),
      lessThan(1),
    );
  });

  test('bootstrap restores saved visibility, lock, style and placements '
      'and reacts to native window events', () async {
    final gw = _FakeDesktopLyricsGateway()
      ..settings[DesktopLyricsSettingKeys.visible] = 'true'
      ..settings[DesktopLyricsSettingKeys.locked] = 'true'
      ..settings[DesktopLyricsSettingKeys.fontSize] = '42'
      ..settings[DesktopLyricsSettingKeys.opacity] = '0.85'
      ..settings[DesktopLyricsSettingKeys.placements] = '{"m1":{"x":10}}';
    late _FakeActions actions;
    final container = ProviderContainer(
      overrides: [
        desktopLyricsGatewayProvider.overrideWithValue(gw),
        playerActionsProvider.overrideWith(
          (ref) => actions = _FakeActions(ref),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await gw.dispose();
    });
    container.read(playerActionsProvider);

    await container.read(desktopLyricsProvider.notifier).bootstrap();

    final state = container.read(desktopLyricsProvider);
    expect(state.visible, isTrue);
    expect(state.locked, isTrue);
    expect(state.fontSize, 42);
    expect(state.opacity, closeTo(0.85, 0.001));
    expect(gw.visible, isTrue);
    expect(gw.lastPlacements, '{"m1":{"x":10}}');

    // Native window events drive playback and persist state.
    gw.controller.add(
      const bridge.DesktopLyricsEventDto.control(
        action: bridge.DesktopLyricsControlDto.playPause,
      ),
    );
    gw.controller.add(
      const bridge.DesktopLyricsEventDto.control(
        action: bridge.DesktopLyricsControlDto.next,
      ),
    );
    gw.controller.add(
      const bridge.DesktopLyricsEventDto.lockChanged(locked: false),
    );
    gw.controller.add(
      const bridge.DesktopLyricsEventDto.placementChanged(
        json: '{"m1":{"x":99}}',
      ),
    );
    gw.controller.add(const bridge.DesktopLyricsEventDto.closed());
    await Future<void>.delayed(Duration.zero);

    expect(actions.toggles, 1);
    expect(actions.nexts, 1);
    expect(container.read(desktopLyricsProvider).locked, isFalse);
    expect(container.read(desktopLyricsProvider).visible, isFalse);
    expect(gw.settings[DesktopLyricsSettingKeys.placements], '{"m1":{"x":99}}');
    expect(gw.settings[DesktopLyricsSettingKeys.visible], 'false');
  });

  test('buildDesktopLyricsDoc preserves translations and karaoke words', () {
    final doc = buildDesktopLyricsDoc(
      trackId: 7,
      track: null,
      lyrics: const ParsedLyrics(
        synced: true,
        lines: [
          LyricLine(
            1200,
            'Hello world',
            translation: '你好世界',
            words: [
              LyricWord(1200, 1600, 'Hello '),
              LyricWord(1600, 2100, 'world'),
            ],
          ),
        ],
      ),
    );

    expect(doc.synced, isTrue);
    expect(doc.lines, hasLength(1));
    expect(doc.lines.first.translation, '你好世界');
    expect(doc.lines.first.words, hasLength(2));
  });

  testWidgets('settings section toggles desktop lyrics when supported', (
    tester,
  ) async {
    final gw = _FakeDesktopLyricsGateway(supported: true);
    addTearDown(gw.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopLyricsGatewayProvider.overrideWithValue(gw)],
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: const Scaffold(
            body: SingleChildScrollView(child: DesktopLyricsSettingsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('desktop-lyrics.visible')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('desktop-lyrics.visible')));
    await tester.pumpAndSettle();

    expect(gw.visible, isTrue);
    expect(gw.settings[DesktopLyricsSettingKeys.visible], 'true');
  });
}
