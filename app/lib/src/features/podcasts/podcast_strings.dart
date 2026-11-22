// 播客页面的全部双语文案（SRC-12）。

import '../../l10n/app_l10n.dart';

abstract final class PodcastStrings {
  static String get title => L10n.tr('播客', 'Podcasts');
  static String get eyebrow => L10n.tr('播客', 'PODCASTS');

  static String get tabSubscriptions => L10n.tr('订阅', 'Subscriptions');
  static String get tabDiscover => L10n.tr('发现', 'Discover');

  static String get searchHint =>
      L10n.tr('搜索播客，或粘贴 RSS 链接', 'Search podcasts or paste an RSS URL');
  static String get clear => L10n.tr('清除', 'Clear');
  static String get refresh => L10n.tr('刷新', 'Refresh');
  static String get refreshAll => L10n.tr('刷新全部订阅', 'Refresh All');
  static String get retry => L10n.tr('重试', 'Retry');
  static String get region => L10n.tr('地区', 'Region');
  static String get allGenres => L10n.tr('全部', 'All');
  static String get topCharts => L10n.tr('排行榜', 'Top Charts');
  static String get searchResults => L10n.tr('搜索结果', 'Search Results');

  static String get addByUrl => L10n.tr('通过 RSS 地址添加', 'Add by RSS URL');
  static const addByUrlHint = 'https://example.com/feed.xml';
  static String get addByUrlBody =>
      L10n.tr('支持 RSS / Atom 地址与 feed:// 链接。', 'Supports RSS / Atom and feed:// URLs.');
  static String get add => L10n.tr('添加', 'Add');
  static String get cancel => L10n.tr('取消', 'Cancel');
  static String get importOpml => L10n.tr('导入 OPML', 'Import OPML');
  static String get exportOpml => L10n.tr('导出 OPML', 'Export OPML');
  static String get radio => L10n.tr('网络电台', 'Internet Radio');
  static String get more => L10n.tr('更多', 'More');

  static String get subscribe => L10n.tr('订阅', 'Subscribe');
  static String get subscribed => L10n.tr('已订阅', 'Subscribed');
  static String get unsubscribe => L10n.tr('取消订阅', 'Unsubscribe');
  static String get subscribedDone => L10n.tr('已订阅', 'Subscribed');
  static String get unsubscribedDone => L10n.tr('已取消订阅', 'Unsubscribed');
  static String get markPlayed => L10n.tr('标记为已播放', 'Mark as Played');
  static String get markUnplayed => L10n.tr('标记为未播放', 'Mark as Unplayed');
  static String get markAllPlayed => L10n.tr('全部标记为已播放', 'Mark All Played');
  static String get played => L10n.tr('已播放', 'Played');
  static String get play => L10n.tr('播放', 'Play');
  static String get resume => L10n.tr('继续', 'Resume');
  static String get openLink => L10n.tr('复制单集链接', 'Copy Episode Link');
  static String get linkCopied => L10n.tr('已复制链接', 'Link copied');

  static String get continueListening => L10n.tr('继续收听', 'Continue Listening');
  static String get latestEpisodes => L10n.tr('最新单集', 'Latest Episodes');
  static String get mySubscriptions => L10n.tr('我的订阅', 'My Subscriptions');
  static String get episodes => L10n.tr('单集', 'Episodes');
  static String get loadMore => L10n.tr('加载更多', 'Load More');

  static String get subscriptionsEmpty => L10n.tr('还没有订阅播客', 'No Subscriptions Yet');
  static String get subscriptionsEmptyBody => L10n.tr(
    '去「发现」看看排行榜，或者搜索、粘贴 RSS 地址添加节目。也可以导入其他播客应用导出的 OPML。',
    'Explore charts in Discover, search, paste an RSS feed URL, or import an OPML file.',
  );
  static String get goDiscover => L10n.tr('去发现', 'Explore Discover');
  static String get searchEmpty => L10n.tr('没有找到节目', 'No Shows Found');
  static String get searchEmptyBody =>
      L10n.tr('换一个关键词试试，或直接粘贴节目的 RSS 地址。', 'Try another keyword or paste an RSS URL.');
  static String get chartEmpty =>
      L10n.tr('这个地区暂时没有排行榜数据', 'No chart data for this region');
  static String get episodesEmpty =>
      L10n.tr('这个节目还没有可播放的单集', 'No playable episodes yet');
  static String get loadFailed => L10n.tr('播客加载失败', 'Failed to load podcasts');
  static String get networkHint => L10n.tr(
    '检查网络连接；节目内容来自节目自己的 RSS。',
    'Check your network connection; episodes are fetched directly from their RSS feeds.',
  );
  static String get actionFailed => L10n.tr('操作失败', 'Action failed');
  static String get opening => L10n.tr('正在读取节目…', 'Loading show…');

  static String refreshReport(int refreshed, int failed, int added) {
    if (L10n.isEnglishActive) {
      final parts = <String>['Refreshed $refreshed'];
      if (added > 0) parts.add('$added new');
      if (failed > 0) parts.add('$failed failed');
      return parts.join(', ');
    }
    final parts = <String>['已刷新 $refreshed 个节目'];
    if (added > 0) parts.add('新增 $added 集');
    if (failed > 0) parts.add('$failed 个失败');
    return parts.join('，');
  }

  static String importReport(int added, int already, int failed) {
    if (L10n.isEnglishActive) {
      final parts = <String>['Subscribed $added'];
      if (already > 0) parts.add('$already existing');
      if (failed > 0) parts.add('$failed failed');
      return parts.join(', ');
    }
    final parts = <String>['新订阅 $added 个'];
    if (already > 0) parts.add('$already 个已订阅');
    if (failed > 0) parts.add('$failed 个暂时读取失败');
    return parts.join('，');
  }

  static String exported(String name) => L10n.tr('已保存 $name', 'Saved $name');
  static String unplayedCount(int n) => L10n.tr('$n 集未听', '$n unplayed');
  static String episodeCount(int n) => L10n.tr('$n 集', '$n episodes');
  static String lastError(String e) => L10n.tr('上次刷新失败：$e', 'Last refresh failed: $e');
}

/// 播客目录地区列表。
List<(String, String)> get podcastRegions => [
  ('CN', L10n.tr('中国大陆', 'China')),
  ('HK', L10n.tr('香港', 'Hong Kong')),
  ('TW', L10n.tr('台湾地区', 'Taiwan')),
  ('SG', L10n.tr('新加坡', 'Singapore')),
  ('MY', L10n.tr('马来西亚', 'Malaysia')),
  ('US', L10n.tr('美国', 'United States')),
  ('GB', L10n.tr('英国', 'United Kingdom')),
  ('CA', L10n.tr('加拿大', 'Canada')),
  ('AU', L10n.tr('澳大利亚', 'Australia')),
  ('JP', L10n.tr('日本', 'Japan')),
  ('KR', L10n.tr('韩国', 'South Korea')),
  ('DE', L10n.tr('德国', 'Germany')),
  ('FR', L10n.tr('法国', 'France')),
  ('ES', L10n.tr('西班牙', 'Spain')),
  ('IT', L10n.tr('意大利', 'Italy')),
  ('BR', L10n.tr('巴西', 'Brazil')),
  ('IN', L10n.tr('印度', 'India')),
];

/// 播客分类 ID。
List<(int, String)> get podcastGenres => [
  (1321, L10n.tr('商业', 'Business')),
  (1318, L10n.tr('科技', 'Technology')),
  (1324, L10n.tr('社会与文化', 'Society & Culture')),
  (1303, L10n.tr('喜剧', 'Comedy')),
  (1489, L10n.tr('新闻', 'News')),
  (1304, L10n.tr('教育', 'Education')),
  (1487, L10n.tr('历史', 'History')),
  (1301, L10n.tr('艺术', 'Arts')),
  (1309, L10n.tr('电视与电影', 'TV & Film')),
  (1310, L10n.tr('音乐', 'Music')),
  (1533, L10n.tr('科学', 'Science')),
  (1512, L10n.tr('健康', 'Health')),
  (1502, L10n.tr('休闲', 'Leisure')),
  (1305, L10n.tr('儿童与家庭', 'Kids & Family')),
  (1488, L10n.tr('真实罪案', 'True Crime')),
  (1483, L10n.tr('小说', 'Fiction')),
  (1545, L10n.tr('体育', 'Sports')),
  (1314, L10n.tr('宗教与灵修', 'Religion & Spirituality')),
];
