// Turns the core's raw lyrics text into display lines.
//
// TODO(core): this is presentation parsing only (timestamps → lines). If the
// core ever returns pre-parsed lines, drop this file.

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';
import 'package:lekis/src/rust/api/dto.dart';

/// One word (or character) of an enhanced-LRC line.
///
/// [text] keeps the spacing from the source, so joining the words of a line
/// reproduces [LyricLine.text] exactly. That keeps highlight offsets stable.
@immutable
class LyricWord {
  const LyricWord(this.startMs, this.endMs, this.text);

  final int startMs;

  /// End of this word's highlight. Inferred from the next word or the next
  /// line, so it never runs past the line it belongs to.
  final int endMs;

  final String text;
}

@immutable
class LyricLine {
  const LyricLine(this.startMs, this.text, {this.translation, this.words});

  /// Start time, or -1 for unsynced lines.
  final int startMs;
  final String text;

  /// Secondary text sharing this line's timestamp (usually a translation or
  /// romanisation), shown smaller under [text].
  final String? translation;

  /// Word timings from enhanced LRC; null when the line only has a line-level
  /// timestamp. Concatenating every word's text gives back [text].
  final List<LyricWord>? words;

  bool get hasWordTimings => words != null && words!.isNotEmpty;

  bool get isInstrumental => text.trim().isEmpty;
}

@immutable
class ParsedLyrics {
  const ParsedLyrics({
    required this.lines,
    required this.synced,
    this.offsetMs = 0,
  });

  final List<LyricLine> lines;
  final bool synced;

  /// User-configured offset applied by the parser, shown by the quick-sync
  /// controls in the lyrics pane.
  final int offsetMs;

  bool get isEmpty => lines.isEmpty;

  /// Index of the line playing at [positionMs]; -1 before the first line.
  int indexAt(int positionMs) {
    if (!synced || lines.isEmpty) return -1;
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].startMs <= positionMs) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  static ParsedLyrics parse(LyricsDto dto) {
    final content = dto.content.replaceFirst('﻿', '');
    final parsed = switch (dto.format) {
      LyricsFormatDto.lrc ||
      LyricsFormatDto.enhancedLrc => _parseLrc(content, dto.offsetMs),
      LyricsFormatDto.ttml => _parseTtml(content, dto.offsetMs),
      // Some tags / sidecars are LRC without saying so.
      LyricsFormatDto.plain =>
        _looksLikeLrc(content) ? _parseLrc(content, dto.offsetMs) : null,
    };
    // Anything without usable timestamps falls back to static text. The
    // offset is kept only for synced lyrics; a plain text view has nothing to
    // shift, so it stays at zero.
    if (parsed == null) return _plain(content);
    return ParsedLyrics(
      lines: parsed.lines,
      synced: parsed.synced,
      offsetMs: dto.offsetMs,
    );
  }

  static ParsedLyrics _plain(String content) {
    final lines = [
      for (final l in content.replaceAll('\r', '').split('\n'))
        // Drop LRC metadata tags ([ar:...], [ti:...]) if any slipped in.
        if (!_lrcTag.hasMatch(l.trim())) l.trimRight(),
    ];
    // Trim blank lines at both ends; keep inner blank lines (stanzas).
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return ParsedLyrics(
      synced: false,
      lines: [for (final l in lines) LyricLine(-1, l)],
    );
  }
}

/// Metadata-only LRC line such as `[ar:Artist]` or `[length: 03:12]`.
final RegExp _lrcTag = RegExp(r'^\[[a-zA-Z#]+:[^\]]*\]$');

/// True when at least half of the non-blank lines start with an LRC
/// timestamp.
bool _looksLikeLrc(String content) {
  var stamped = 0, total = 0;
  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || _lrcTag.hasMatch(line)) continue;
    total++;
    if (line.startsWith(_lrcTime)) stamped++;
  }
  return total > 0 && stamped * 2 >= total;
}

/// Sorts timed lines (stable: same-time lines keep file order) and folds
/// lines sharing a timestamp into one line plus a translation.
List<LyricLine> _foldTimed(List<LyricLine> raw) {
  final indexed = [for (var i = 0; i < raw.length; i++) (i, raw[i])]
    ..sort((a, b) {
      final c = a.$2.startMs.compareTo(b.$2.startMs);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  final out = <LyricLine>[];
  var i = 0;
  while (i < indexed.length) {
    final start = indexed[i].$2.startMs;
    LyricLine? primary;
    final extra = <String>[];
    while (i < indexed.length && indexed[i].$2.startMs == start) {
      final line = indexed[i].$2;
      if (line.text.isNotEmpty) {
        if (primary == null) {
          primary = line;
        } else {
          extra.add(line.text);
        }
      }
      i++;
    }
    out.add(
      LyricLine(
        start,
        primary?.text ?? '',
        translation: extra.isEmpty ? null : extra.join('\n'),
        // Word timings only make sense for the primary (sung) line.
        words: primary?.words,
      ),
    );
  }
  return out;
}

final RegExp _lrcTime = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final RegExp _lrcOffset = RegExp(
  r'^\[offset:\s*([+-]?\d+)\s*\]',
  caseSensitive: false,
);

/// Enhanced-LRC word tag, e.g. `<00:12.34>`.
final RegExp _wordTime = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');

/// Used when a line's last word has no following line timestamp.
const int _wordFallbackMs = 600;

/// Keeps millisecond arithmetic inside the range the UI expects.
const int _maxMs = 1 << 31;

int _fractionMs(String? frac) {
  if (frac == null || frac.isEmpty) return 0;
  return switch (frac.length) {
    1 => int.parse(frac) * 100,
    2 => int.parse(frac) * 10,
    _ => int.parse(frac.substring(0, 3)),
  };
}

int _matchMs(RegExpMatch m) =>
    int.parse(m.group(1)!) * 60000 +
    int.parse(m.group(2)!) * 1000 +
    _fractionMs(m.group(3));

int _clampMs(int ms) => ms < 0 ? 0 : (ms > _maxMs ? _maxMs : ms);

/// Splits the body of an enhanced-LRC line into timed words.
///
/// Text before the first `<mm:ss.xx>` belongs to the start of the line (some
/// writers only tag the words after the first one). Word texts keep their
/// spacing; leading/trailing whitespace is trimmed exactly like the line text
/// so the words can be laid out as one string.
({String text, List<LyricWord>? words}) _splitWords(
  String body,
  int lineStartMs,
) {
  final plain = body.replaceAll(_wordTime, '');
  final text = plain.trim();
  final tags = _wordTime.allMatches(body).toList();
  if (tags.isEmpty) return (text: text, words: null);

  final segments = <(int, String)>[];
  var cursor = 0;
  var startMs = lineStartMs;
  for (final tag in tags) {
    final chunk = body.substring(cursor, tag.start);
    if (chunk.isNotEmpty) segments.add((startMs, chunk));
    startMs = _matchMs(tag);
    cursor = tag.end;
  }
  final tail = body.substring(cursor);
  if (tail.isNotEmpty) segments.add((startMs, tail));

  // Match text.trim(): remove leading/trailing whitespace, even when it is
  // spread over several word segments (e.g. text before the first tag).
  var leading = plain.length - plain.trimLeft().length;
  final keptLength = text.length;
  final firstPass = <(int, String)>[];
  for (final segment in segments) {
    var s = segment.$2;
    if (leading > 0) {
      final drop = leading < s.length ? leading : s.length;
      s = s.substring(drop);
      leading -= drop;
    }
    if (s.isNotEmpty) firstPass.add((segment.$1, s));
  }
  final trimmed = <(int, String)>[];
  var used = 0;
  for (final segment in firstPass) {
    final remaining = keptLength - used;
    if (remaining <= 0) break;
    var s = segment.$2;
    if (s.length > remaining) s = s.substring(0, remaining);
    if (s.isNotEmpty) trimmed.add((segment.$1, s));
    used += s.length;
  }
  if (trimmed.isEmpty) return (text: text, words: null);

  final words = <LyricWord>[];
  for (var i = 0; i < trimmed.length; i++) {
    final (start, chunk) = trimmed[i];
    final end = i + 1 < trimmed.length
        ? trimmed[i + 1].$1
        : start + _wordFallbackMs;
    words.add(LyricWord(start, end < start ? start : end, chunk));
  }
  return (text: text, words: words);
}

/// Applies [shift] to word times and clamps each end to the next word / line.
List<LyricWord>? _shiftWords(
  List<LyricWord>? words,
  int shift,
  int? lineEndMs,
) {
  if (words == null || words.isEmpty) return null;
  final out = <LyricWord>[];
  for (final word in words) {
    final start = _clampMs(word.startMs - shift);
    var end = _clampMs(word.endMs - shift);
    if (end < start) end = start;
    out.add(LyricWord(start, end, word.text));
  }
  for (var i = 0; i < out.length - 1; i++) {
    final word = out[i];
    final nextStart = out[i + 1].startMs;
    if (word.endMs > nextStart) {
      out[i] = LyricWord(
        word.startMs,
        nextStart < word.startMs ? word.startMs : nextStart,
        word.text,
      );
    }
  }
  final last = out.last;
  if (lineEndMs != null && lineEndMs > last.startMs) {
    out[out.length - 1] = LyricWord(last.startMs, lineEndMs, last.text);
  } else if (last.endMs <= last.startMs) {
    out[out.length - 1] = LyricWord(
      last.startMs,
      _clampMs(last.startMs + _wordFallbackMs),
      last.text,
    );
  }
  return out;
}

/// LRC convention: a positive offset makes lyrics appear sooner.
ParsedLyrics? _parseLrc(String content, int userOffsetMs) {
  var fileOffset = 0;
  final out = <LyricLine>[];
  for (final raw in content.replaceAll('\r', '').split('\n')) {
    final line = raw.trim();
    final off = _lrcOffset.firstMatch(line);
    if (off != null) {
      fileOffset = int.tryParse(off.group(1)!) ?? 0;
      continue;
    }
    final stamps = _lrcTime.allMatches(line).toList();
    if (stamps.isEmpty) continue;
    final firstMs = _matchMs(stamps.first);
    final body = line.substring(stamps.last.end);
    final split = _splitWords(body, firstMs);
    for (final m in stamps) {
      final ms = _matchMs(m);
      // Repeated timestamps reuse the same body; move its word tags along.
      final delta = ms - firstMs;
      out.add(
        LyricLine(
          ms,
          split.text,
          words: split.words == null
              ? null
              : [
                  for (final w in split.words!)
                    LyricWord(w.startMs + delta, w.endMs + delta, w.text),
                ],
        ),
      );
    }
  }
  if (out.isEmpty) return null;
  final shift = fileOffset + userOffsetMs;
  final folded = _foldTimed(out);
  final lines = <LyricLine>[];
  for (var i = 0; i < folded.length; i++) {
    final line = folded[i];
    final next = i + 1 < folded.length
        ? _clampMs(folded[i + 1].startMs - shift)
        : null;
    lines.add(
      LyricLine(
        _clampMs(line.startMs - shift),
        line.text,
        translation: line.translation,
        words: _shiftWords(line.words, shift, next),
      ),
    );
  }
  return ParsedLyrics(synced: true, lines: lines);
}

int? _ttmlTime(String t) {
  t = t.trim();
  if (t.endsWith('ms')) {
    final ms = double.tryParse(t.substring(0, t.length - 2));
    return ms != null && ms.isFinite ? ms.round() : null;
  }
  if (t.endsWith('s')) {
    final s = double.tryParse(t.substring(0, t.length - 1));
    return s == null || !s.isFinite ? null : (s * 1000).round();
  }
  final parts = t.split(':');
  double total = 0;
  for (final p in parts) {
    final v = double.tryParse(p);
    if (v == null || !v.isFinite || v < 0) return null;
    total = total * 60 + v;
  }
  return (total * 1000).round();
}

ParsedLyrics? _parseTtml(String content, int userOffsetMs) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(content);
  } on XmlException {
    return null;
  }
  final rows = <LyricLine>[];
  for (final p in document.descendantElements.where(
    (e) => e.name.local == 'p',
  )) {
    final start = _ttmlTime(p.getAttribute('begin') ?? '');
    if (start == null) continue;
    final text = StringBuffer();
    final translations = <String>[];
    final words = <LyricWord>[];
    void read(XmlNode node) {
      if (node is XmlText || node is XmlCDATA) {
        text.write(node.value);
        return;
      }
      if (node is! XmlElement) return;
      final role = node.attributes
          .where((a) => a.name.local == 'role')
          .firstOrNull
          ?.value;
      if (role == 'x-translation' || role == 'x-roman') {
        translations.add(node.innerText.trim());
        return;
      }
      if (node.name.local == 'br') {
        text.write(' ');
        return;
      }
      final begin = _ttmlTime(node.getAttribute('begin') ?? '');
      final end = _ttmlTime(node.getAttribute('end') ?? '');
      if (begin != null &&
          end != null &&
          end >= begin &&
          node.childElements.isEmpty) {
        final value = node.innerText;
        words.add(
          LyricWord(
            _clampMs(begin - userOffsetMs),
            _clampMs(end - userOffsetMs),
            value,
          ),
        );
        text.write(value);
      } else {
        for (final child in node.children) {
          read(child);
        }
      }
    }

    for (final child in p.children) {
      read(child);
    }
    final primary = text.toString().trim();
    final at = _clampMs(start - userOffsetMs);
    rows.add(
      LyricLine(
        at,
        primary,
        words: words.isNotEmpty && words.map((w) => w.text).join() == primary
            ? words
            : null,
      ),
    );
    for (final translation in translations) {
      if (translation.isNotEmpty) rows.add(LyricLine(at, translation));
    }
  }
  if (rows.isEmpty) return null;
  return ParsedLyrics(synced: true, lines: _foldTimed(rows));
}
