// 网络电台页面的全部双语文案。

import '../../l10n/app_l10n.dart';

abstract final class RadioStrings {
  static String get title => L10n.tr('网络电台', 'Internet Radio');
  static const eyebrow = 'RADIO';
  static String get intro => L10n.tr(
    '来自 Radio Browser 的公共电台。收藏后会保存在本机，也可以添加自己的流地址。',
    'Public stations from Radio Browser. Favorites are saved locally, or add your own stream URL.',
  );

  static String get tabPopular => L10n.tr('热门', 'Popular');
  static String get tabFavorites => L10n.tr('收藏', 'Favorites');
  static String get tabCustom => L10n.tr('自定义', 'Custom');
  static String get tabRecent => L10n.tr('最近', 'Recent');

  static String get searchHint =>
      L10n.tr('搜索电台名称，例如 Jazz、新闻、BBC', 'Search stations, e.g. Jazz, News, BBC');
  static String get localSearchHint =>
      L10n.tr('搜索名称、国家或标签', 'Search name, country, or tag');
  static String get sortBy => L10n.tr('排序', 'Sort');
  static String get sortDefault => L10n.tr('默认顺序', 'Default Order');
  static String get sortNameAsc => L10n.tr('名称 A–Z', 'Name A–Z');
  static String get sortNameDesc => L10n.tr('名称 Z–A', 'Name Z–A');
  static String get noMatch => L10n.tr('没有匹配的电台', 'No Matching Stations');
  static String get noMatchBody => L10n.tr(
    '试试其他名称、国家、语言或标签。',
    'Try another name, country, language, or tag.',
  );
  static String get clearSearch => L10n.tr('清除搜索', 'Clear Search');
  static String get search => L10n.tr('搜索', 'Search');
  static String get clear => L10n.tr('清除', 'Clear');
  static String get refresh => L10n.tr('刷新', 'Refresh');
  static String get retry => L10n.tr('重试', 'Retry');

  static String get allCountries => L10n.tr('全部国家', 'All Countries');
  static String get allLanguages => L10n.tr('全部语言', 'All Languages');
  static String get allTags => L10n.tr('全部标签', 'All Tags');
  static String get country => L10n.tr('国家', 'Country');
  static String get language => L10n.tr('语言', 'Language');
  static String get tag => L10n.tr('标签 / 流派', 'Tag / Genre');
  static String get filterFailed => L10n.tr(
    '筛选选项加载失败，已显示常用列表',
    'Failed to load filters; showing common list',
  );

  static String get popularEmpty => L10n.tr('没有找到电台', 'No Stations Found');
  static String get popularEmptyBody => L10n.tr(
    '换一个关键词，或者放宽国家 / 语言 / 标签筛选。',
    'Try another keyword or broaden country / language / tag filters.',
  );
  static String get favoritesEmpty =>
      L10n.tr('还没有收藏电台', 'No Favorite Stations');
  static String get favoritesEmptyBody => L10n.tr(
    '在热门列表里点小心心，收藏的电台会出现在这里。',
    'Tap the heart on any station to save it here.',
  );
  static String get customEmpty => L10n.tr('还没有自定义电台', 'No Custom Stations');
  static String get customEmptyBody => L10n.tr(
    '添加一个 http/https 流地址，或者直接粘贴 M3U / PLS 播放列表。',
    'Add an http/https stream URL or paste an M3U / PLS playlist.',
  );
  static String get recentEmpty => L10n.tr('还没有播放过电台', 'No Recent Stations');
  static String get recentEmptyBody => L10n.tr(
    '点一个电台开始收听，最近播放会保留在这里。',
    'Play any station and it will appear here.',
  );

  static String get loadFailed => L10n.tr('电台加载失败', 'Failed to load stations');
  static String get loadMore => L10n.tr('加载更多', 'Load More');
  static String get loadingMore => L10n.tr('正在加载…', 'Loading…');
  static String get noMore => L10n.tr('没有更多了', 'No more stations');

  static String get play => L10n.tr('播放', 'Play');
  static String get pause => L10n.tr('暂停', 'Pause');
  static String get favorite => L10n.tr('收藏', 'Favorite');
  static String get unfavorite => L10n.tr('取消收藏', 'Unfavorite');
  static String get deleteCustom => L10n.tr('删除自定义电台', 'Delete Station');
  static String get deleteTitle =>
      L10n.tr('删除这个自定义电台？', 'Delete this station?');
  static String deleteBody(String name) => L10n.tr(
    '“$name”会从本机删除，收藏记录也会一起移除。',
    '"$name" will be removed from this device and your favorites.',
  );
  static String get delete => L10n.tr('删除', 'Delete');
  static String get cancel => L10n.tr('取消', 'Cancel');

  static String get addCustom => L10n.tr('添加自定义电台', 'Add Custom Station');
  static String get addCustomShort => L10n.tr('添加电台', 'Add Station');
  static String get fieldName => L10n.tr('名称', 'Name');
  static String get fieldNameHint => L10n.tr('例如：我的爵士电台', 'e.g. My Jazz Radio');
  static String get fieldAddress =>
      L10n.tr('流地址 / M3U / PLS', 'Stream URL / M3U / PLS');
  static String get fieldAddressHint => L10n.tr(
    'http:// 或 https:// 开头。也可以粘贴 M3U/PLS 文本，自动取第一条流地址。',
    'Starts with http:// or https://, or paste M3U/PLS playlist text.',
  );
  static String get fieldHomepage => L10n.tr('主页（可选）', 'Homepage (Optional)');
  static const fieldHomepageHint = 'https://example.com';
  static String get parseAndSave => L10n.tr('解析并保存', 'Parse & Save');
  static String get saving => L10n.tr('正在保存…', 'Saving…');
  static String get addressRequired =>
      L10n.tr('请粘贴流地址或 M3U/PLS 内容', 'Please enter a stream URL or M3U/PLS');
  static String get added => L10n.tr('已添加自定义电台', 'Custom station added');
  static String get deleted => L10n.tr('已删除自定义电台', 'Custom station deleted');

  static String get started => L10n.tr('正在播放', 'Now playing');
  static String get played => L10n.tr('开始播放', 'Playback started');
  static String get favoriteDone => L10n.tr('已收藏', 'Added to favorites');
  static String get unfavoriteDone =>
      L10n.tr('已取消收藏', 'Removed from favorites');
  static String get actionFailed => L10n.tr('操作失败', 'Action failed');
  static String get networkHint => L10n.tr(
    '公共 API 可能被网络环境拦截；会自动轮换 Radio Browser 镜像。',
    'Public API mirrors rotate automatically if blocked.',
  );
}
