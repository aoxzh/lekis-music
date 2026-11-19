// Turns the core's raw lyrics text into display lines.
//
// TODO(core): this is presentation parsing only (timestamps → lines). If the
// core ever returns pre-parsed lines, drop this file.

import 'package:flutter/foundation.dart';
import 'package:lekis/src/rust/api/dto.dart';

@immutable
class LyricLine {
  const LyricLine(this.startMs, this.text, {this.translation});

  /// Start time, or -1 for unsynced lines.
  final int startMs;
  final String text;

  /// Secondary text sharing this line's timestamp (usually a translation or
  /// romanisation), shown smaller under [text].
  final String? translation;

  bool get isInstrumental => text.trim().isEmpty;
}

@immutable
class ParsedLyrics {
  const ParsedLyrics({required this.lines, required this.synced});

  final List<LyricLine> lines;
  final bool synced;

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
    // Anything without usable timestamps falls back to static text.
    return parsed ?? _plain(content);
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
    final group = <String>[];
    while (i < indexed.length && indexed[i].$2.startMs == start) {
      final t = indexed[i].$2.text;
      if (t.isNotEmpty) group.add(t);
      i++;
    }
    out.add(
      LyricLine(
        start,
        group.isEmpty ? '' : group.first,
        translation: group.length > 1 ? group.skip(1).join('\n') : null,
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
final RegExp _wordTime = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');

int _fractionMs(String? frac) {
  if (frac == null || frac.isEmpty) return 0;
  return switch (frac.length) {
    1 => int.parse(frac) * 100,
    2 => int.parse(frac) * 10,
    _ => int.parse(frac.substring(0, 3)),
  };
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
    final text = line
        .substring(stamps.last.end)
        .replaceAll(_wordTime, '')
        .trim();
    for (final m in stamps) {
      final ms =
          int.parse(m.group(1)!) * 60000 +
          int.parse(m.group(2)!) * 1000 +
          _fractionMs(m.group(3));
      out.add(LyricLine(ms, text));
    }
  }
  if (out.isEmpty) return null;
  final shift = fileOffset + userOffsetMs;
  return ParsedLyrics(
    synced: true,
    lines: [
      for (final l in _foldTimed(out))
        LyricLine(
          (l.startMs - shift).clamp(0, 1 << 31),
          l.text,
          translation: l.translation,
        ),
    ],
  );
}

final RegExp _ttmlP = RegExp(
  r'<p\b([^>]*)>(.*?)</p>',
  dotAll: true,
  caseSensitive: false,
);
final RegExp _ttmlBegin = RegExp(r'\bbegin="([^"]+)"');
final RegExp _tags = RegExp(r'<[^>]+>');

int? _ttmlTime(String t) {
  t = t.trim();
  if (t.endsWith('ms')) {
    return double.tryParse(t.substring(0, t.length - 2))?.round();
  }
  if (t.endsWith('s')) {
    final s = double.tryParse(t.substring(0, t.length - 1));
    return s == null ? null : (s * 1000).round();
  }
  final parts = t.split(':');
  double total = 0;
  for (final p in parts) {
    final v = double.tryParse(p);
    if (v == null) return null;
    total = total * 60 + v;
  }
  return (total * 1000).round();
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

ParsedLyrics? _parseTtml(String content, int userOffsetMs) {
  final out = <LyricLine>[];
  for (final m in _ttmlP.allMatches(content)) {
    final begin = _ttmlBegin.firstMatch(m.group(1)!);
    final ms = begin == null ? null : _ttmlTime(begin.group(1)!);
    if (ms == null) continue;
    final text = _unescape(
      m.group(2)!.replaceAll(RegExp(r'<br\s*/?>'), ' ').replaceAll(_tags, ''),
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    out.add(LyricLine((ms - userOffsetMs).clamp(0, 1 << 31), text));
  }
  if (out.isEmpty) return null;
  return ParsedLyrics(synced: true, lines: _foldTimed(out));
}
