// 补全候选的解析：把核心给的 payload_json 变成界面能直接展示的数据。
// 格式由 lekis-core/src/enrich.rs 决定：
// - artwork: {"url", "width", "height"}
// - lyrics:  {"format", "content"}
// - tags:    TrackOverlay（snake_case 字段，空字段表示不改）

import 'dart:convert';

import '../../rust/api/dto.dart';
import 'strings.dart';

sealed class EnrichProposal {
  const EnrichProposal();
}

final class ArtworkProposal extends EnrichProposal {
  const ArtworkProposal({required this.url, this.width, this.height});
  final String url;
  final int? width;
  final int? height;
}

final class LyricsProposal extends EnrichProposal {
  const LyricsProposal({required this.format, required this.content});
  final String format;
  final String content;
}

final class TagsProposal extends EnrichProposal {
  const TagsProposal(this.values);

  /// 只包含建议修改的字段。
  final Map<TagField, String> values;
}

final class UnknownProposal extends EnrichProposal {
  const UnknownProposal();
}

enum TagField {
  title('title'),
  artists('artists'),
  albumTitle('album_title'),
  year('year'),
  trackNo('track_no'),
  discNo('disc_no'),
  genres('genres');

  const TagField(this.jsonKey);
  final String jsonKey;

  String get label => switch (this) {
    TagField.title => EnrichStrings.tagTitle,
    TagField.artists => EnrichStrings.tagArtists,
    TagField.albumTitle => EnrichStrings.tagAlbum,
    TagField.year => EnrichStrings.tagYear,
    TagField.trackNo => EnrichStrings.tagTrackNo,
    TagField.discNo => EnrichStrings.tagDiscNo,
    TagField.genres => EnrichStrings.tagGenres,
  };
}

String _display(Object? v) => switch (v) {
  null => '',
  List<Object?> list => list.map((e) => '$e').join(EnrichStrings.listSeparator),
  _ => '$v',
};

int? _int(Object? v) => v is num ? v.toInt() : null;

/// 解析候选内容；格式不对时返回 [UnknownProposal]，不抛异常。
EnrichProposal parseProposal(EnrichCandidateDto candidate) {
  final Object? decoded;
  try {
    decoded = jsonDecode(candidate.payloadJson);
  } on FormatException {
    return const UnknownProposal();
  }
  if (decoded is! Map<String, Object?>) return const UnknownProposal();
  switch (candidate.kind) {
    case 'artwork':
      final url = decoded['url'];
      if (url is! String || url.isEmpty) return const UnknownProposal();
      return ArtworkProposal(
        url: url,
        width: _int(decoded['width']),
        height: _int(decoded['height']),
      );
    case 'lyrics':
      final content = decoded['content'];
      if (content is! String) return const UnknownProposal();
      final format = decoded['format'];
      return LyricsProposal(
        format: format is String ? format : 'lrc',
        content: content,
      );
    case 'tags':
      final values = <TagField, String>{};
      for (final f in TagField.values) {
        final text = _display(decoded[f.jsonKey]);
        if (text.isNotEmpty) values[f] = text;
      }
      return values.isEmpty ? const UnknownProposal() : TagsProposal(values);
    default:
      return const UnknownProposal();
  }
}

String kindLabel(String kind) => switch (kind) {
  'artwork' => EnrichStrings.kindArtwork,
  'lyrics' => EnrichStrings.kindLyrics,
  'tags' => EnrichStrings.kindTags,
  _ => EnrichStrings.kindOther,
};

final _lrcTag = RegExp(r'\[[^\]]*\]|<\d+:\d+(?:\.\d+)?>');

/// 歌词预览：去掉 LRC 时间标签和元信息行，取前几行非空文本。
String lyricsPreview(String content, {int maxLines = 6}) => content
    .split(RegExp(r'\r?\n'))
    .map((l) => l.replaceAll(_lrcTag, '').trim())
    .where((l) => l.isNotEmpty)
    .take(maxLines)
    .join('\n');

/// 一个标签字段的“当前 → 建议”。
class TagChange {
  const TagChange(this.field, this.current, this.proposed);
  final TagField field;
  final String current;
  final String proposed;
  bool get changed => current != proposed;
}

String currentTagValue(TrackDto track, TagField field) => switch (field) {
  TagField.title => track.title,
  TagField.artists => _display(track.artists),
  TagField.albumTitle => track.albumTitle ?? '',
  TagField.year => _display(track.year),
  TagField.trackNo => _display(track.trackNo),
  TagField.discNo => _display(track.discNo),
  TagField.genres => _display(track.genres),
};

List<TagChange> diffTags(TrackDto? track, TagsProposal proposal) => [
  for (final e in proposal.values.entries)
    TagChange(
      e.key,
      track == null ? '' : currentTagValue(track, e.key),
      e.value,
    ),
];
