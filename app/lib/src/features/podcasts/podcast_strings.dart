// 播客页面的全部中文文案（SRC-12）。

abstract final class PodcastStrings {
  static const title = '播客';
  static const eyebrow = '播客';

  static const tabSubscriptions = '订阅';
  static const tabDiscover = '发现';

  static const searchHint = '搜索播客，或粘贴 RSS / Apple Podcasts 链接';
  static const clear = '清除';
  static const refresh = '刷新';
  static const refreshAll = '刷新全部订阅';
  static const retry = '重试';
  static const region = '地区';
  static const allGenres = '全部';
  static const topCharts = '排行榜';
  static const searchResults = '搜索结果';

  static const addByUrl = '通过 RSS 地址添加';
  static const addByUrlHint = 'https://example.com/feed.xml';
  static const addByUrlBody =
      '支持 RSS / Atom 地址、feed:// 链接和 Apple Podcasts 网页链接。';
  static const add = '添加';
  static const cancel = '取消';
  static const importOpml = '导入 OPML';
  static const exportOpml = '导出 OPML';
  static const radio = '网络电台';
  static const more = '更多';

  static const subscribe = '订阅';
  static const subscribed = '已订阅';
  static const unsubscribe = '取消订阅';
  static const subscribedDone = '已订阅';
  static const unsubscribedDone = '已取消订阅';
  static const markPlayed = '标记为已播放';
  static const markUnplayed = '标记为未播放';
  static const markAllPlayed = '全部标记为已播放';
  static const played = '已播放';
  static const play = '播放';
  static const resume = '继续';
  static const openLink = '复制单集链接';
  static const linkCopied = '已复制链接';

  static const continueListening = '继续收听';
  static const latestEpisodes = '最新单集';
  static const mySubscriptions = '我的订阅';
  static const episodes = '单集';
  static const loadMore = '加载更多';

  static const subscriptionsEmpty = '还没有订阅播客';
  static const subscriptionsEmptyBody =
      '去「发现」看看排行榜，或者搜索、粘贴 RSS 地址添加节目。也可以导入其他播客应用导出的 OPML。';
  static const goDiscover = '去发现';
  static const searchEmpty = '没有找到节目';
  static const searchEmptyBody = '换一个关键词试试，或直接粘贴节目的 RSS 地址。';
  static const chartEmpty = '这个地区暂时没有排行榜数据';
  static const episodesEmpty = '这个节目还没有可播放的单集';
  static const loadFailed = '播客加载失败';
  static const networkHint = '检查网络连接；目录数据来自 Apple Podcasts，节目内容来自节目自己的 RSS。';
  static const actionFailed = '操作失败';
  static const opening = '正在读取节目…';

  static String refreshReport(int refreshed, int failed, int added) {
    final parts = <String>['已刷新 $refreshed 个节目'];
    if (added > 0) parts.add('新增 $added 集');
    if (failed > 0) parts.add('$failed 个失败');
    return parts.join('，');
  }

  static String importReport(int added, int already, int failed) {
    final parts = <String>['新订阅 $added 个'];
    if (already > 0) parts.add('$already 个已订阅');
    if (failed > 0) parts.add('$failed 个暂时读取失败');
    return parts.join('，');
  }

  static String exported(String name) => '已保存 $name';
  static String unplayedCount(int n) => '$n 集未听';
  static String episodeCount(int n) => '$n 集';
  static String lastError(String e) => '上次刷新失败：$e';
}

/// Apple Podcasts 的地区（目录 / 排行榜按地区区分）。
const podcastRegions = <(String, String)>[
  ('CN', '中国大陆'),
  ('HK', '香港'),
  ('TW', '台湾地区'),
  ('SG', '新加坡'),
  ('MY', '马来西亚'),
  ('US', '美国'),
  ('GB', '英国'),
  ('CA', '加拿大'),
  ('AU', '澳大利亚'),
  ('JP', '日本'),
  ('KR', '韩国'),
  ('DE', '德国'),
  ('FR', '法国'),
  ('ES', '西班牙'),
  ('IT', '意大利'),
  ('BR', '巴西'),
  ('IN', '印度'),
];

/// Apple Podcasts 的顶级分类 ID。
const podcastGenres = <(int, String)>[
  (1321, '商业'),
  (1318, '科技'),
  (1324, '社会与文化'),
  (1303, '喜剧'),
  (1489, '新闻'),
  (1304, '教育'),
  (1487, '历史'),
  (1301, '艺术'),
  (1309, '电视与电影'),
  (1310, '音乐'),
  (1533, '科学'),
  (1512, '健康'),
  (1502, '休闲'),
  (1305, '儿童与家庭'),
  (1488, '真实罪案'),
  (1483, '小说'),
  (1545, '体育'),
  (1314, '宗教与灵修'),
];
