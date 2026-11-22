// 标签编辑对话框的纯数据模型（方便单元测试）。
//
// 单曲编辑：字段预填 "文件标签 → 已有覆盖层"，保存时空字段表示不覆盖。
// 批量编辑：字段留空表示"保持每首歌原来的值"，只把用户填写的字段合并进各自覆盖层。

import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';

/// 一次标签编辑表单的文本值。数字字段也用字符串保存，便于"留空 = 不修改"。
class TagEditDraft {
  TagEditDraft({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.trackNo = '',
    this.discNo = '',
    this.year = '',
    this.genre = '',
    this.comment = '',
    this.composer = '',
    this.lyricist = '',
    this.musicbrainzTrackId = '',
    this.musicbrainzAlbumId = '',
  });

  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final String trackNo;
  final String discNo;
  final String year;
  final String genre;
  final String comment;
  final String composer;
  final String lyricist;
  final String musicbrainzTrackId;
  final String musicbrainzAlbumId;

  /// 单曲编辑的初始值：覆盖层优先，其次文件标签，最后资料库里的展示值。
  factory TagEditDraft.forTrack({
    required TrackDto track,
    TrackTagOverridesDto? overrides,
    TrackTagOverridesDto? fileTags,
  }) {
    final o = overrides;
    final f = fileTags;
    return TagEditDraft(
      title: o?.title ?? f?.title ?? track.title,
      artist:
          o?.artist ??
          f?.artist ??
          (track.artists.isEmpty ? '' : track.artists.join(' / ')),
      album: o?.album ?? f?.album ?? track.albumTitle ?? '',
      albumArtist: o?.albumArtist ?? f?.albumArtist ?? '',
      trackNo: _numberText(o?.trackNo ?? f?.trackNo ?? track.trackNo),
      discNo: _numberText(o?.discNo ?? f?.discNo ?? track.discNo),
      year: _numberText(o?.year ?? f?.year ?? track.year),
      genre:
          o?.genre ??
          f?.genre ??
          (track.genres.isEmpty ? '' : track.genres.join('; ')),
      comment: o?.comment ?? f?.comment ?? '',
      composer: o?.composer ?? f?.composer ?? '',
      lyricist: o?.lyricist ?? f?.lyricist ?? '',
      musicbrainzTrackId: o?.musicbrainzTrackId ?? f?.musicbrainzTrackId ?? '',
      musicbrainzAlbumId: o?.musicbrainzAlbumId ?? f?.musicbrainzAlbumId ?? '',
    );
  }

  /// 表单里有没有用户输入。
  bool get isEmpty =>
      title.trim().isEmpty &&
      artist.trim().isEmpty &&
      album.trim().isEmpty &&
      albumArtist.trim().isEmpty &&
      trackNo.trim().isEmpty &&
      discNo.trim().isEmpty &&
      year.trim().isEmpty &&
      genre.trim().isEmpty &&
      comment.trim().isEmpty &&
      composer.trim().isEmpty &&
      lyricist.trim().isEmpty &&
      musicbrainzTrackId.trim().isEmpty &&
      musicbrainzAlbumId.trim().isEmpty;

  /// 校验数字字段；返回给用户看的中文提示，合法时返回 `null`。
  String? validate() {
    final track = _parseNumber(trackNo);
    if (track.error != null) return L10n.tr('曲目号：${track.error}', 'Track: ${track.error}');
    if (track.value != null && (track.value! < 1 || track.value! > 9999)) {
      return L10n.tr('曲目号必须是 1~9999', 'Track must be 1–9999');
    }
    final disc = _parseNumber(discNo);
    if (disc.error != null) return L10n.tr('碟片号：${disc.error}', 'Disc: ${disc.error}');
    if (disc.value != null && (disc.value! < 1 || disc.value! > 9999)) {
      return L10n.tr('碟片号必须是 1~9999', 'Disc must be 1–9999');
    }
    final year = _parseNumber(this.year);
    if (year.error != null) return L10n.tr('年份：${year.error}', 'Year: ${year.error}');
    if (year.value != null && (year.value! < 1000 || year.value! > 9999)) {
      return L10n.tr('年份必须是 1000~9999', 'Year must be 1000–9999');
    }
    return null;
  }

  /// 单曲模式：直接生成完整覆盖层。空字段 = 不覆盖。
  TrackTagOverridesDto toOverrides() {
    final track = _parseNumber(trackNo);
    final disc = _parseNumber(discNo);
    final year = _parseNumber(this.year);
    return TrackTagOverridesDto(
      title: _text(title),
      artist: _text(artist),
      album: _text(album),
      albumArtist: _text(albumArtist),
      trackNo: track.value,
      discNo: disc.value,
      year: year.value,
      genre: _text(genre),
      comment: _text(comment),
      composer: _text(composer),
      lyricist: _text(lyricist),
      musicbrainzTrackId: _text(musicbrainzTrackId),
      musicbrainzAlbumId: _text(musicbrainzAlbumId),
    );
  }

  /// 批量模式：只把用户填写的字段合并到一首歌现有的覆盖层上。
  TrackTagOverridesDto? mergeInto(TrackTagOverridesDto? existing) {
    final track = _parseNumber(trackNo);
    final disc = _parseNumber(discNo);
    final year = _parseNumber(this.year);
    final merged = TrackTagOverridesDto(
      title: _text(title) ?? existing?.title,
      artist: _text(artist) ?? existing?.artist,
      album: _text(album) ?? existing?.album,
      albumArtist: _text(albumArtist) ?? existing?.albumArtist,
      trackNo: track.value ?? existing?.trackNo,
      discNo: disc.value ?? existing?.discNo,
      year: year.value ?? existing?.year,
      genre: _text(genre) ?? existing?.genre,
      comment: _text(comment) ?? existing?.comment,
      composer: _text(composer) ?? existing?.composer,
      lyricist: _text(lyricist) ?? existing?.lyricist,
      musicbrainzTrackId:
          _text(musicbrainzTrackId) ?? existing?.musicbrainzTrackId,
      musicbrainzAlbumId:
          _text(musicbrainzAlbumId) ?? existing?.musicbrainzAlbumId,
    );
    return _isEmptyOverrides(merged) ? null : merged;
  }

  static bool _isEmptyOverrides(TrackTagOverridesDto value) =>
      value.title == null &&
      value.artist == null &&
      value.album == null &&
      value.albumArtist == null &&
      value.trackNo == null &&
      value.discNo == null &&
      value.year == null &&
      value.genre == null &&
      value.comment == null &&
      value.composer == null &&
      value.lyricist == null &&
      value.musicbrainzTrackId == null &&
      value.musicbrainzAlbumId == null;

  static String? _text(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _numberText(int? value) => value?.toString() ?? '';

  static ({int? value, String? error}) _parseNumber(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return (value: null, error: null);
    final parsed = int.tryParse(trimmed);
    if (parsed == null) {
      return (value: null, error: L10n.tr('请输入整数', 'Enter a whole number'));
    }
    return (value: parsed, error: null);
  }
}

/// 写回结果里字段 key 的中文名。
String tagFieldLabel(String key) => switch (key) {
  'title' => L10n.tr('标题', 'Title'),
  'artist' => L10n.tr('艺人', 'Artist'),
  'album' => L10n.tr('专辑', 'Album'),
  'album_artist' => L10n.tr('专辑艺人', 'Album Artist'),
  'track_no' => L10n.tr('曲目号', 'Track'),
  'disc_no' => L10n.tr('碟片号', 'Disc'),
  'year' => L10n.tr('年份', 'Year'),
  'genre' => L10n.tr('流派', 'Genre'),
  'comment' => L10n.tr('评论', 'Comment'),
  'composer' => L10n.tr('作曲', 'Composer'),
  'lyricist' => L10n.tr('作词', 'Lyricist'),
  'musicbrainz_track_id' => L10n.tr('MusicBrainz 录音 ID', 'MusicBrainz Recording ID'),
  'musicbrainz_album_id' => L10n.tr('MusicBrainz 专辑 ID', 'MusicBrainz Release ID'),
  _ => key,
};
