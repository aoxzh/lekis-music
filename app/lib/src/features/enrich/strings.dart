// 补全确认页的全部双语文案。

import '../../l10n/app_l10n.dart';

abstract final class EnrichStrings {
  static String get title => L10n.tr('待确认的补全', 'Metadata Review');
  static String titleWithCount(int n) =>
      L10n.tr('待确认的补全（$n）', 'Metadata Review ($n)');
  static String get acceptAll => L10n.tr('全部接受', 'Accept All');
  static String get acceptAllConfirmTitle => L10n.tr('全部接受？', 'Accept All?');
  static String acceptAllConfirmBody(int n) => L10n.tr(
    '将应用全部 $n 条自动找到的封面、歌词和标签。之后仍可以在曲目信息里手动改回。',
    'Apply all $n auto-matched artwork, lyrics, and tag updates. You can still edit them manually later.',
  );
  static String get cancel => L10n.tr('取消', 'Cancel');
  static String get confirm => L10n.tr('全部接受', 'Accept All');
  static String acceptedAll(int n) => L10n.tr('已接受 $n 条', 'Accepted $n');
  static String get accept => L10n.tr('接受', 'Accept');
  static String get reject => L10n.tr('拒绝', 'Reject');
  static String get accepted => L10n.tr('已接受', 'Accepted');
  static String get rejected => L10n.tr('已拒绝', 'Rejected');
  static String get emptyTitle => L10n.tr('没有需要确认的内容', 'Nothing to Review');
  static String get emptyBody => L10n.tr(
    'Lekis 自动找到的封面、歌词和标签，把握不大时会放在这里等你确认。',
    'Low-confidence artwork, lyrics, and tag matches appear here for your approval.',
  );
  static String get loadFailed => L10n.tr('读取待确认列表失败', 'Failed to load review queue');
  static String get retry => L10n.tr('重试', 'Retry');

  static String get kindArtwork => L10n.tr('封面', 'Artwork');
  static String get kindLyrics => L10n.tr('歌词', 'Lyrics');
  static String get kindTags => L10n.tr('标签', 'Tags');
  static String get kindOther => L10n.tr('其他', 'Other');

  static String get current => L10n.tr('当前', 'Current');
  static String get proposed => L10n.tr('建议', 'Proposed');
  static String get none => L10n.tr('无', 'None');
  static String get unknownTrack => L10n.tr('未知曲目', 'Unknown Track');
  static String score(int percent) =>
      L10n.tr('匹配度 $percent%', 'Match $percent%');
  static String fromSource(String source) =>
      L10n.tr('来自 $source', 'From $source');
  static String dimensions(int w, int h) => '$w × $h';
  static String get unreadablePayload =>
      L10n.tr('这条建议的内容无法解析，可以直接拒绝。', 'This suggestion cannot be parsed and can be rejected.');

  static String get tagTitle => L10n.tr('标题', 'Title');
  static String get tagArtists => L10n.tr('艺人', 'Artists');
  static String get tagAlbum => L10n.tr('专辑', 'Album');
  static String get tagYear => L10n.tr('年份', 'Year');
  static String get tagTrackNo => L10n.tr('曲目号', 'Track #');
  static String get tagDiscNo => L10n.tr('碟片号', 'Disc #');
  static String get tagGenres => L10n.tr('流派', 'Genres');
  static String get listSeparator => L10n.tr('、', ', ');
}
