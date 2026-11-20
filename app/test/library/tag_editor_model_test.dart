import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/tag_editor_model.dart';
import 'package:lekis/src/rust/api/dto.dart';

TrackDto track({
  String title = '文件标题',
  List<String> artists = const ['文件艺人'],
  String? album = '文件专辑',
  int? trackNo = 1,
  int? discNo = 1,
  int? year = 2001,
  List<String> genres = const ['流行'],
}) => TrackDto(
  id: 1,
  uid: 'uid-1',
  title: title,
  artists: artists,
  albumId: 10,
  albumTitle: album,
  trackNo: trackNo,
  discNo: discNo,
  year: year,
  durationMs: BigInt.from(1000),
  genres: genres,
  artworkId: null,
  overlay: null,
  loved: false,
  rating: null,
  playCount: 0,
);

void main() {
  group('TagEditDraft', () {
    test('覆盖层优先于文件标签，文件标签优先于资料库展示值', () {
      final draft = TagEditDraft.forTrack(
        track: track(),
        fileTags: const TrackTagOverridesDto(
          title: '文件标签',
          albumArtist: '文件专辑艺人',
          comment: '文件评论',
        ),
        overrides: const TrackTagOverridesDto(title: '覆盖标题'),
      );
      expect(draft.title, '覆盖标题');
      expect(draft.albumArtist, '文件专辑艺人');
      expect(draft.comment, '文件评论');
      expect(draft.artist, '文件艺人');
      expect(draft.genre, '流行');
      expect(draft.trackNo, '1');
    });

    test('批量模式只合并填写的字段', () {
      final draft = TagEditDraft(title: ' 新标题 ', year: ' 2024 ');
      final merged = draft.mergeInto(
        const TrackTagOverridesDto(artist: '原覆盖艺人', album: '原覆盖专辑'),
      );
      expect(merged, isNotNull);
      expect(merged!.title, '新标题');
      expect(merged.year, 2024);
      expect(merged.artist, '原覆盖艺人');
      expect(merged.album, '原覆盖专辑');
    });

    test('空表单批量合并是空操作', () {
      final draft = TagEditDraft(title: '   ');
      expect(draft.mergeInto(null), isNull);
    });

    test('数字字段校验和空值处理', () {
      expect(TagEditDraft(trackNo: 'x').validate(), contains('整数'));
      expect(TagEditDraft(year: '99').validate(), contains('1000~9999'));
      expect(TagEditDraft(trackNo: '0').validate(), contains('1~9999'));
      final values = TagEditDraft(
        title: '  标题  ',
        trackNo: ' 3 ',
        discNo: '',
      ).toOverrides();
      expect(values.title, '标题');
      expect(values.trackNo, 3);
      expect(values.discNo, isNull);
    });

    test('字段 key 有中文标签', () {
      expect(tagFieldLabel('album_artist'), '专辑艺人');
      expect(tagFieldLabel('musicbrainz_track_id'), 'MusicBrainz 录音 ID');
    });
  });
}
