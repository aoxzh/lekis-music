import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_controller.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_settings_section.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/desktop_lyrics.dart' as bridge;
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakeDesktopLyricsGateway implements DesktopLyricsGateway {
  _FakeDesktopLyricsGateway({this.supported = true});

  final bool supported;
  final Map<String, String> settings = {};
  final StreamController<bridge.DesktopLyricsEventDto> controller =
      StreamController<bridge.DesktopLyricsEventDto>.broadcast();
  bool visible = false;
  bool locked = false;
  bridge.DesktopLyricsStyleDto? lastStyle;
  String? lastPlacements;

  @override
  bool isSupported() => supported;

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
