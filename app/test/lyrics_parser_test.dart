import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/rust/api/dto.dart';

ParsedLyrics parse(String content, LyricsFormatDto format, {int offset = 0}) =>
    ParsedLyrics.parse(
      LyricsDto(
        format: format,
        content: content,
        source: 'test',
        offsetMs: offset,
        confidence: 1,
      ),
    );

void main() {
  test('LRC lines are timed, sorted and metadata is skipped', () {
    final l = parse(
      '[ti:Song]\n[ar:Someone]\n[00:12.50]second\n[00:01.2]first\n',
      LyricsFormatDto.lrc,
    );
    expect(l.synced, isTrue);
    expect(l.lines.map((e) => e.text), ['first', 'second']);
    expect(l.lines.map((e) => e.startMs), [1200, 12500]);
  });

  test('one line with several timestamps repeats', () {
    final l = parse('[00:01.00][00:30.00]chorus', LyricsFormatDto.lrc);
    expect(l.lines.map((e) => e.startMs), [1000, 30000]);
  });

  test('enhanced LRC exposes per-word timings', () {
    final l = parse(
      '[00:05.00]<00:05.00>hello <00:05.40>world\n[00:06.20]next',
      LyricsFormatDto.enhancedLrc,
    );
    final line = l.lines.first;
    expect(line.text, 'hello world');
    expect(line.words, isNotNull);
    expect(line.words!.map((w) => w.text), ['hello ', 'world']);
    expect(line.words!.map((w) => w.startMs), [5000, 5400]);
    expect(line.words!.map((w) => w.endMs), [5400, 6200]);
    expect(line.words!.map((w) => w.text).join(), line.text);
  });

  test('enhanced LRC text before the first tag starts at the line time', () {
    final l = parse(
      '[00:10.00]Hello <00:10.60>world',
      LyricsFormatDto.enhancedLrc,
    );
    final words = l.lines.single.words!;
    expect(words.map((w) => w.text), ['Hello ', 'world']);
    expect(words.first.startMs, 10000);
    expect(words.last.startMs, 10600);
    expect(l.lines.single.text, 'Hello world');
    expect(words.map((w) => w.text).join(), l.lines.single.text);
  });

  test('enhanced LRC keeps punctuation and CJK words intact', () {
    final l = parse(
      '[00:01.00]Hello, <00:01.40>world! <00:02.00>你好，<00:02.30>世界！'
      '\n[00:03.00]end',
      LyricsFormatDto.enhancedLrc,
    );
    final line = l.lines.first;
    expect(line.text, 'Hello, world! 你好，世界！');
    expect(line.words!.map((w) => w.text), [
      'Hello, ',
      'world! ',
      '你好，',
      '世界！',
    ]);
    expect(line.words!.map((w) => w.startMs), [1000, 1400, 2000, 2300]);
    expect(line.words!.last.endMs, 3000);
    expect(line.words!.map((w) => w.text).join(), line.text);
  });

  test('enhanced LRC words follow file and user offsets', () {
    final l = parse(
      '[offset:500]\n'
      '[00:10.00]<00:10.00>one <00:10.40>two\n'
      '[00:11.00]next',
      LyricsFormatDto.enhancedLrc,
      offset: 250,
    );
    final line = l.lines.first;
    expect(line.startMs, 9250);
    expect(line.words!.map((w) => w.startMs), [9250, 9650]);
    expect(line.words!.map((w) => w.endMs), [9650, 10250]);
  });

  test('enhanced LRC last word falls back without a following line', () {
    final l = parse('[00:01.00]<00:01.00>solo', LyricsFormatDto.enhancedLrc);
    final word = l.lines.single.words!.single;
    expect(word.startMs, 1000);
    expect(word.endMs, greaterThan(word.startMs));
  });

  test('line without word tags has no word timings', () {
    final l = parse('[00:01.00]plain line', LyricsFormatDto.lrc);
    expect(l.lines.single.words, isNull);
    expect(l.lines.single.hasWordTimings, isFalse);
  });

  test('translation fold keeps word timings from the sung line', () {
    final l = parse(
      '[00:02.00]<00:02.00>原文 <00:02.50>歌词\n[00:02.00]translation',
      LyricsFormatDto.enhancedLrc,
    );
    expect(l.lines, hasLength(1));
    expect(l.lines.single.text, '原文 歌词');
    expect(l.lines.single.translation, 'translation');
    expect(l.lines.single.words!.map((w) => w.startMs), [2000, 2500]);
  });

  test('repeated timestamps move word tags along', () {
    final l = parse(
      '[00:01.00][00:30.00]<00:01.00>a <00:01.40>b',
      LyricsFormatDto.enhancedLrc,
    );
    expect(l.lines, hasLength(2));
    expect(l.lines.first.words!.map((w) => w.startMs), [1000, 1400]);
    expect(l.lines.last.words!.map((w) => w.startMs), [30000, 30400]);
  });

  test('lines sharing a timestamp fold into text + translation', () {
    final l = parse(
      '[00:02.00]原文\n[00:02.00]translation\n[00:04.00]next',
      LyricsFormatDto.lrc,
    );
    expect(l.lines, hasLength(2));
    expect(l.lines.first.text, '原文');
    expect(l.lines.first.translation, 'translation');
    expect(l.lines.last.translation, isNull);
  });

  test('file and user offsets shift lines (positive = sooner)', () {
    final l = parse(
      '[offset:500]\n[00:02.00]a',
      LyricsFormatDto.lrc,
      offset: 250,
    );
    expect(l.lines.single.startMs, 1250);
  });

  test('plain text that is really LRC is parsed as synced', () {
    final l = parse('[00:01.00]a\n[00:02.00]b', LyricsFormatDto.plain);
    expect(l.synced, isTrue);
    expect(l.lines, hasLength(2));
  });

  test('plain text keeps stanzas and trims outer blank lines', () {
    final l = parse('\n\nline 1\n\nline 2\n\n', LyricsFormatDto.plain);
    expect(l.synced, isFalse);
    expect(l.lines.map((e) => e.text), ['line 1', '', 'line 2']);
  });

  test('indexAt finds the active line', () {
    final l = parse('[00:01.00]a\n[00:03.00]b', LyricsFormatDto.lrc);
    expect(l.indexAt(0), -1);
    expect(l.indexAt(1000), 0);
    expect(l.indexAt(2999), 0);
    expect(l.indexAt(60000), 1);
  });

  test('AMLL word spans keep their times and translation stays separate', () {
    final l = parse(
      '<tt xmlns:m="http://www.w3.org/ns/ttml#metadata"><body>'
      '<p begin="1s"><span begin="1s" end="1.5s">青</span>'
      '<span begin="1.6s" end="2s">空</span>'
      '<span m:role="x-translation">蓝天</span></p></body></tt>',
      LyricsFormatDto.ttml,
    );
    expect(l.lines.single.text, '青空');
    expect(l.lines.single.translation, '蓝天');
    expect(l.lines.single.words!.last.startMs, 1600);
    expect(l.lines.single.words!.first.endMs, 1500);
  });

  test('TTML paragraphs are timed', () {
    final l = parse(
      '<tt><body><div>'
      '<p begin="00:01.500">one &amp; two</p>'
      '<p begin="3s">three</p>'
      '</div></body></tt>',
      LyricsFormatDto.ttml,
    );
    expect(l.lines.map((e) => e.text), ['one & two', 'three']);
    expect(l.lines.map((e) => e.startMs), [1500, 3000]);
  });
}
