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

  test('enhanced LRC drops per-word timestamps', () {
    final l = parse(
      '[00:05.00]<00:05.00>hello <00:05.40>world',
      LyricsFormatDto.enhancedLrc,
    );
    expect(l.lines.single.text, 'hello world');
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
