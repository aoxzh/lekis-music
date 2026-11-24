import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/now_playing/lyrics_editor_sheet.dart';
import 'package:lekis/src/features/now_playing/lyrics_view.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/error.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const embedded = LyricsDto(
  format: LyricsFormatDto.lrc,
  content: '[00:01.00]Original embedded fixture',
  source: 'embedded',
  offsetMs: 0,
  confidence: 1,
);
const review = LyricsDto(
  format: LyricsFormatDto.plain,
  content: 'Original review fixture',
  source: 'lrclib',
  offsetMs: 200,
  confidence: .7,
);

class _Api implements RustLibApi {
  var active = 10;
  LyricsDto candidate = review;
  final activations = <int>[];
  var retries = 0;
  var lookups = 0;
  Completer<void>? pending;
  bool failActivation = false;
  Object? retryError;
  LyricsDto? retryResult;
  LyricsDto? saved;
  @override
  Future<LyricsDto?> crateApiCoreLyrics({required int trackId}) async {
    lookups++;
    return active == 10
        ? embedded
        : active == 20
        ? candidate
        : null;
  }

  @override
  Future<List<LyricsRowDto>> crateApiCoreLyricsVersions({
    required int trackId,
  }) async => [
    LyricsRowDto(
      id: 10,
      trackId: trackId,
      lyrics: embedded,
      isActive: active == 10,
    ),
    LyricsRowDto(
      id: 20,
      trackId: trackId,
      lyrics: candidate,
      isActive: active == 20,
    ),
  ];
  @override
  Future<void> crateApiCoreActivateLyrics({
    required int trackId,
    required int lyricsId,
  }) async {
    expect(trackId, 7);
    activations.add(lyricsId);
    await pending?.future;
    if (failActivation) throw StateError('Failed');
    active = lyricsId;
  }

  @override
  Future<LyricsDto?> crateApiCoreRetryLyrics({required int trackId}) async {
    expect(trackId, 7);
    retries += 1;
    if (retryError != null) throw retryError!;
    return retryResult;
  }

  @override
  Future<int> crateApiCoreSetLyrics({
    required int trackId,
    required LyricsDto lyrics,
  }) async {
    saved = lyrics;
    return 30;
  }

  @override
  Future<void> crateApiCoreSetLyricsOffset({
    required int trackId,
    required int offsetMs,
  }) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Api api;
  setUp(() {
    api = _Api();
    RustLib.initMock(api: api);
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    RustLib.dispose();
  });
  Future<void> mount(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1100, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: lekisLightTheme(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showLyricsEditor(context, ref, 7),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  String content(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('lyrics-editor.content')))
      .controller!
      .text;

  testWidgets('selects the stored version by ID only after host success', (
    tester,
  ) async {
    await mount(tester);
    expect(content(tester), embedded.content);
    api.pending = Completer<void>();
    final choice = find.byKey(const ValueKey('lyrics-editor.version.20'));
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pump();
    expect(api.activations, [20]);
    expect(content(tester), embedded.content);
    expect(tester.widget<ListTile>(choice).onTap, isNull);
    api.pending!.complete();
    await tester.pumpAndSettle();
    expect(content(tester), review.content);
    expect(tester.widget<ListTile>(choice).onTap, isNull, reason: 'now active');
  });
  testWidgets('preview shows parsed candidate without activating it', (
    tester,
  ) async {
    api.candidate = const LyricsDto(
      format: LyricsFormatDto.ttml,
      content: '<tt><body><div><p begin="00:01.000" end="00:02.000">Preview line</p></div></body></tt>',
      source: 'candidate',
      offsetMs: 0,
      confidence: .7,
    );
    await mount(tester);
    final preview = find.byKey(const ValueKey('lyrics-editor.preview.20'));
    await tester.ensureVisible(preview);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.text('Preview line'), findsOneWidget);
    expect(find.textContaining('<tt>'), findsNothing);
    expect(api.activations, isEmpty);
    expect(content(tester), embedded.content);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lyrics-editor.version.20')));
    await tester.pumpAndSettle();
    expect(api.activations, [20]);
  });
  testWidgets('failed selection preserves active content', (tester) async {
    api.failActivation = true;
    await mount(tester);
    final choice = find.byKey(const ValueKey('lyrics-editor.version.20'));
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(api.active, 10);
    expect(content(tester), embedded.content);
    expect(find.textContaining('切换歌词失败'), findsOneWidget);
    expect(tester.widget<ListTile>(choice).onTap, isNotNull);
  });
  testWidgets('explicit retry distinguishes no result from network failure', (
    tester,
  ) async {
    await mount(tester);
    final retry = find.byKey(const ValueKey('lyrics-editor.retry'));
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(api.retries, 1);
    expect(api.lookups, 1);
    expect(content(tester), embedded.content);
    expect(find.textContaining('未找到可自动使用的歌词'), findsOneWidget);
    api.retryError = const CoreError(
      kind: ErrorKind.network,
      detail: 'private remote detail',
    );
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(api.retries, 2);
    expect(find.textContaining('请检查网络后重试'), findsOneWidget);
    expect(find.textContaining('private remote detail'), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-editor.notice')), findsNothing);
    expect(content(tester), embedded.content);
  });
  testWidgets('empty playback lyrics opens review-only candidates', (
    tester,
  ) async {
    api.active = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: lekisLightTheme(),
          home: const Scaffold(body: LyricsView(trackId: 7)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找歌词版本'));
    await tester.pumpAndSettle();
    final choice = find.byKey(const ValueKey('lyrics-editor.version.20'));
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(api.activations, [20]);
    expect(api.retries, 0);
  });
  testWidgets('retry preserves an unsaved lyrics draft', (tester) async {
    await mount(tester);
    await tester.enterText(
      find.byKey(const ValueKey('lyrics-editor.content')),
      'Unsaved draft',
    );
    await tester.tap(find.byKey(const ValueKey('lyrics-editor.retry')));
    await tester.pumpAndSettle();
    expect(api.retries, 1);
    expect(content(tester), 'Unsaved draft');
    await tester.tap(find.byKey(const ValueKey('lyrics-editor.save')));
    await tester.pumpAndSettle();
    expect(api.saved?.content, 'Unsaved draft');
  });
  testWidgets('manual save sends selected format and content', (tester) async {
    await mount(tester);
    await tester.enterText(
      find.byKey(const ValueKey('lyrics-editor.content')),
      '[00:01.00]Original manual fixture',
    );
    await tester.tap(find.byKey(const ValueKey('lyrics-editor.save')));
    await tester.pumpAndSettle();
    expect(api.saved?.source, 'manual');
    expect(api.saved?.format, LyricsFormatDto.lrc);
    expect(api.saved?.content, '[00:01.00]Original manual fixture');
  });
}
