import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/playlists/playlist_m3u.dart';
import 'package:lekis/src/rust/api/dto.dart';

void main() {
  test('import report maps matched and missing counts', () {
    final outcome = PlaylistImportOutcome.fromReport(
      const PlaylistImportReportDto(
        playlistId: 7,
        matched: 2,
        total: 5,
        missing: ['C:\\old\\a.mp3', 'missing/b.flac', 'c.flac'],
      ),
    );

    expect(outcome.playlistId, 7);
    expect(outcome.matched, 2);
    expect(outcome.total, 5);
    expect(outcome.unmatched, 3);
    expect(outcome.hasMissing, isTrue);
    expect(outcome.summary, '已导入 2 首歌曲，3 个路径未匹配（共 5 条）。');
  });

  test('import report summary covers full, empty and partial matches', () {
    final full = PlaylistImportOutcome.fromReport(
      const PlaylistImportReportDto(
        playlistId: 1,
        matched: 3,
        total: 3,
        missing: [],
      ),
    );
    expect(full.hasMissing, isFalse);
    expect(full.summary, '已导入 3 首歌曲（共 3 条）。');

    final empty = PlaylistImportOutcome.fromReport(
      const PlaylistImportReportDto(
        playlistId: 2,
        matched: 0,
        total: 0,
        missing: [],
      ),
    );
    expect(empty.summary, '文件里没有条目，已创建空歌单。');

    final none = PlaylistImportOutcome.fromReport(
      const PlaylistImportReportDto(
        playlistId: 3,
        matched: 0,
        total: 2,
        missing: ['a', 'b'],
      ),
    );
    expect(none.unmatched, 2);
    expect(none.summary, '已导入 0 首歌曲，2 个路径未匹配（共 2 条）。');
  });

  test('export file name keeps Chinese and removes unsafe characters', () {
    expect(playlistM3uFileName('通勤'), '通勤.m3u8');
    expect(playlistM3uFileName('  Rock/Pop: 2026  '), 'Rock_Pop_ 2026.m3u8');
    expect(playlistM3uFileName('...'), 'lekis-playlist.m3u8');
    expect(playlistM3uFileName(''), 'lekis-playlist.m3u8');
  });

  test('playlist name comes from the picked file', () {
    expect(playlistNameFromM3uFile('通勤歌单.m3u8'), '通勤歌单');
    expect(playlistNameFromM3uFile('mix.M3U'), 'mix');
    expect(playlistNameFromM3uFile('  .m3u8'), '导入的歌单');
  });

  test('entry count ignores M3U comments and blanks', () {
    const text =
        '\u{feff}#EXTM3U\n'
        '#EXTINF:10,Artist - Title\n'
        'music/a.flac\n'
        '\n'
        '#EXT-X-VERSION:3\n'
        'music/b.flac\r\n';
    expect(countM3uEntries(text), 2);
    expect(countM3uEntries('#EXTM3U\n'), 0);
  });
}
