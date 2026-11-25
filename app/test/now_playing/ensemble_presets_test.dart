import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/now_playing/lyrics_ensemble.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/lyrics_view.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/settings/lyrics_presets.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const _song = '''<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
<head><metadata>
<ttm:agent xml:id="v1" type="person"><ttm:name>林澈</ttm:name></ttm:agent>
<ttm:agent xml:id="v2" type="person"><ttm:name>沈遥</ttm:name></ttm:agent>
<ttm:agent xml:id="both" type="group"><ttm:name>林澈与沈遥</ttm:name></ttm:agent>
</metadata></head><body><div>
<p begin="1s" end="8s" ttm:agent="v1">渡口留一盏灯<span ttm:role="x-translation">A lantern waits by the ferry.</span></p>
<p begin="3s" end="9s" ttm:agent="v2">我沿潮声归来<span ttm:role="x-translation">I follow the tide back home.</span><span ttm:role="x-bg" begin="4s" end="7s"><![CDATA[慢慢，靠岸]]><span ttm:role="x-translation">Softly, ashore.</span></span></p>
<p begin="9s" end="14s" ttm:agent="both">两岸同一片天</p>
</div></body></tt>''';

ParsedLyrics _parse(String text, LyricsFormatDto format, {int offset = 0}) =>
    ParsedLyrics.parse(
      LyricsDto(
        format: format,
        content: text,
        source: 'sidecar',
        offsetMs: offset,
        confidence: 1,
      ),
    );

class _Position extends PositionController {
  @override
  int build() => 4500;
  void jump(int value) => state = value;
}

class _Setting extends SettingNotifier {
  _Setting(super.key, this.store);
  final Map<String, String> store;
  @override
  Future<String?> build() async => store[key];
  @override
  Future<void> set(String value) async {
    store[key] = value;
    state = AsyncData(value);
  }
}

void main() {
  final output = Platform.environment['LEKIS_ENSEMBLE_SCREENSHOTS'];
  setUpAll(() async {
    if (output == null) return;
    final fontPath =
        Platform.environment['LEKIS_UI_CJK_FONT'] ??
        '/Library/Fonts/Arial Unicode.ttf';
    final font = ByteData.sublistView(await File(fontPath).readAsBytes());
    final semiboldPath = Platform.environment['LEKIS_UI_CJK_SEMIBOLD_FONT'];
    final semibold = semiboldPath == null
        ? null
        : ByteData.sublistView(await File(semiboldPath).readAsBytes());
    for (final family in ['Stage sample', 'PingFang SC', 'Roboto']) {
      final loader = FontLoader(family)..addFont(Future.value(font));
      if (semibold != null) loader.addFont(Future.value(semibold));
      await loader.load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test('explicit LRC voices retain their own translations; ordinary lines have no assigned singer', () {
    final lyric = _parse(
      '[00:01][演唱:林澈]北岸\n[00:01]North bank\n'
      '[00:01]B:南岸\n[00:01]South bank\n'
      '[00:01]和声:归来\n[00:02]合唱:同行',
      LyricsFormatDto.lrc,
    );
    expect(lyric.vocalCues.map((cue) => cue.voice), ['林澈', 'B', null, '合唱']);
    expect(lyric.vocalCues.map((cue) => cue.line.translation), [
      'North bank',
      'South bank',
      null,
      null,
    ]);
    expect(lyric.vocalCues[2].backing, isTrue);
    expect(lyric.vocalCues.last.together, isTrue);
    final plain = _parse(
      '[00:01]归来\n[00:01]Return\n[00:02]同行',
      LyricsFormatDto.lrc,
    );
    expect(plain.vocalCues, isEmpty);
    expect(plain.lines.first.translation, 'Return');
  });

  test(
    'TTML metadata, overlap, CDATA harmony and translations survive offset',
    () {
      final cues = _parse(_song, LyricsFormatDto.ttml, offset: 500).vocalCues;
      expect(cues.map((cue) => cue.voice), ['林澈', '沈遥', null, '林澈与沈遥']);
      expect(cues.map((cue) => cue.line.startMs), [500, 2500, 3500, 8500]);
      expect(cues.map((cue) => cue.endMs), [7500, 8500, 6500, 13500]);
      expect(cues[1].line.translation, 'I follow the tide back home.');
      expect(cues[2].line.text, '慢慢，靠岸');
      expect(cues[2].line.translation, 'Softly, ashore.');
      expect(cues[2].backing, isTrue);
      expect(cues.last.together, isTrue);
    },
  );

  test('timed TTML spans can identify a second voice within a paragraph', () {
    final song = _parse(
      '<tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><p begin="1s" end="8s" ttm:agent="v1">'
      'North<span ttm:agent="v2" begin="3s" end="6s">South</span></p></body></tt>',
      LyricsFormatDto.ttml,
    );
    expect(song.vocalCues.map((cue) => cue.line.text), ['North', 'South']);
    expect(song.vocalCues.last.voice, 'v2');
    expect(song.vocalCues.last.line.startMs, 3000);
    expect(song.vocalCues.last.endMs, 6000);
  });

  testWidgets(
    'unmarked bilingual lyrics stay centered with no singer or harmony label',
    (tester) async {
      final song = _parse(
        '<tt><body><p begin="1s">北岸</p><p begin="1s">North bank</p>'
        '<p begin="6s">南岸</p></body></tt>',
        LyricsFormatDto.ttml,
      );
      expect(song.vocalCues, isEmpty);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [positionProvider.overrideWith(_Position.new)],
          child: MaterialApp(
            home: Scaffold(
              body: EnsembleLyrics(
                lyrics: song,
                style: const TextStyle(fontSize: 30),
                translation: true,
                reduceMotion: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('北岸')).textAlign, TextAlign.center);
      expect(find.text('North bank'), findsOneWidget);
      expect(
        tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data),
        ['北岸', 'North bank', '下一句 · 南岸'],
      );
      expect(find.byType(AnimatedSwitcher), findsNothing);
    },
  );

  for (final (name, size) in [
    ('narrow', const Size(320, 600)),
    ('desktop', const Size(900, 540)),
  ]) {
    testWidgets('lyrics view renders simultaneous parts at $name width', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final key = GlobalKey();
      final position = _Position();
      final settings = {SettingKeys.lyricsStage: 'ensemble'};
      final scope = ProviderContainer(
        overrides: [
          settingProvider.overrideWith2((key) => _Setting(key, settings)),
          lyricsProvider.overrideWith(
            (ref, trackId) async => _parse(_song, LyricsFormatDto.ttml),
          ),
          lyricsPrefetchProvider.overrideWith((ref) {}),
          positionProvider.overrideWith(() => position),
        ],
      );
      addTearDown(scope.dispose);
      final theme = lekisDarkTheme();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: scope,
          child: MaterialApp(
            theme: output == null
                ? theme
                : theme.copyWith(
                    textTheme: theme.textTheme.apply(
                      fontFamily: 'Stage sample',
                    ),
                  ),
            home: RepaintBoundary(
              key: key,
              child: Scaffold(
                body: LyricsView(trackId: 1, compact: name == 'narrow'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final text in [
        '林澈',
        '沈遥',
        '和声',
        '渡口留一盏灯',
        '我沿潮声归来',
        '慢慢，靠岸',
        'A lantern waits by the ferry.',
        'I follow the tide back home.',
        'Softly, ashore.',
      ]) {
        expect(find.text(text).hitTestable(), findsOneWidget, reason: text);
      }
      final first = tester.getRect(find.text('渡口留一盏灯'));
      final second = tester.getRect(find.text('我沿潮声归来'));
      if (name == 'desktop') {
        expect(first.right, lessThan(second.left));
        expect(first.top, closeTo(second.top, 1));
      } else {
        expect(second.top, greaterThan(first.bottom));
      }
      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final data = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            await Directory(output).create(recursive: true);
            await File('$output/$name.png').writeAsBytes(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            );
          } finally {
            image.dispose();
          }
        });
      }
      position.jump(7100);
      await tester.pump();
      expect(find.text('和声'), findsNothing);
      expect(find.text('沈遥'), findsOneWidget);
      position.jump(9100);
      await tester.pump();
      expect(find.text('合唱 · 林澈与沈遥'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      position.jump(4500);
      await scope
          .read(settingProvider(SettingKeys.lyricsTranslation).notifier)
          .set('false');
      await tester.pumpAndSettle();
      expect(find.text('Softly, ashore.'), findsNothing);
      expect(find.text('我沿潮声归来'), findsOneWidget);
      expect(find.byType(EnsembleLyrics), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'save, export to clipboard, import and apply the same five settings in a fresh catalog',
    (tester) async {
      String? clipboard;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = call.arguments['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      Future<void> mount(Map<String, String> store) async {
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              settingProvider.overrideWith2((key) => _Setting(key, store)),
            ],
            child: const MaterialApp(home: Scaffold(body: LyricsPresetTile())),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('歌词舞台预设'));
        await tester.pumpAndSettle();
      }

      Future<void> input(String button, String value) async {
        await tester.tap(find.text(button));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), value);
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
      }

      const appearance = {
        SettingKeys.lyricsStage: 'ensemble',
        SettingKeys.lyricsFontScale: '1.15',
        SettingKeys.lyricsTranslation: 'false',
        SettingKeys.lyricsSparks: 'false',
        SettingKeys.lyricsRuby: 'tone_num',
      };
      await mount({...appearance});
      await input('保存当前组合', '渡口现场');
      await tester.tap(find.byTooltip('复制 JSON'));
      await tester.pumpAndSettle();
      expect(find.text('已复制 JSON'), findsOneWidget);
      final exported = clipboard!;
      expect(jsonDecode(exported)['name'], '渡口现场');
      final destination = <String, String>{};
      await mount(destination);
      await input('保存当前组合', '初始外观');
      await input('导入 JSON', exported);
      expect(find.text('渡口现场'), findsOneWidget);
      expect(destination.keys, [SettingKeys.lyricsPresets]);
      await tester.tap(find.text('渡口现场'));
      await tester.pumpAndSettle();
      for (final entry in appearance.entries) {
        expect(destination[entry.key], entry.value);
      }
      final catalog = destination[SettingKeys.lyricsPresets];
      await input('导入 JSON', exported);
      expect(find.text('已有同名预设，请更换名称。'), findsOneWidget);
      expect(find.text(exported), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('导入 JSON'), findsOneWidget);
      await input(
        '导入 JSON',
        exported.replaceFirst('"version":1', '"version":2'),
      );
      expect(find.text('无法读取歌词预设，请检查 JSON 格式和版本。'), findsOneWidget);
      expect(destination[SettingKeys.lyricsPresets], catalog);
      await mount(destination);
      await tester.tap(find.text('初始外观'));
      await tester.pumpAndSettle();
      expect(destination[SettingKeys.lyricsStage], 'classic');
      await tester.tap(find.text('渡口现场'));
      await tester.pumpAndSettle();
      for (final entry in appearance.entries) {
        expect(destination[entry.key], entry.value);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
