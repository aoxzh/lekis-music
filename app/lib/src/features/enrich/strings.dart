// 补全确认页的全部文案。先写死简体中文，之后换 i18n 时只改这一个文件。

abstract final class EnrichStrings {
  static const title = '待确认的补全';
  static String titleWithCount(int n) => '待确认的补全（$n）';
  static const acceptAll = '全部接受';
  static const acceptAllConfirmTitle = '全部接受？';
  static String acceptAllConfirmBody(int n) =>
      '将应用全部 $n 条自动找到的封面、歌词和标签。之后仍可以在曲目信息里手动改回。';
  static const cancel = '取消';
  static const confirm = '全部接受';
  static String acceptedAll(int n) => '已接受 $n 条';
  static const accept = '接受';
  static const reject = '拒绝';
  static const accepted = '已接受';
  static const rejected = '已拒绝';
  static const emptyTitle = '没有需要确认的内容';
  static const emptyBody = 'Lekis 自动找到的封面、歌词和标签，把握不大时会放在这里等你确认。';
  static const loadFailed = '读取待确认列表失败';
  static const retry = '重试';

  static const kindArtwork = '封面';
  static const kindLyrics = '歌词';
  static const kindTags = '标签';
  static const kindOther = '其他';

  static const current = '当前';
  static const proposed = '建议';
  static const none = '无';
  static const unknownTrack = '未知曲目';
  static String score(int percent) => '匹配度 $percent%';
  static String fromSource(String source) => '来自 $source';
  static String dimensions(int w, int h) => '$w × $h';
  static const unreadablePayload = '这条建议的内容无法解析，可以直接拒绝。';

  static const tagTitle = '标题';
  static const tagArtists = '艺人';
  static const tagAlbum = '专辑';
  static const tagYear = '年份';
  static const tagTrackNo = '曲目号';
  static const tagDiscNo = '碟片号';
  static const tagGenres = '流派';
  static const listSeparator = '、';
}
