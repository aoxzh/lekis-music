// 网络电台页面的全部中文文案。

abstract final class RadioStrings {
  static const title = '网络电台';
  static const eyebrow = 'SRC-11';
  static const intro = '来自 Radio Browser 的公共电台。收藏后会保存在本机，也可以添加自己的流地址。';

  static const tabPopular = '热门';
  static const tabFavorites = '收藏';
  static const tabCustom = '自定义';
  static const tabRecent = '最近';

  static const searchHint = '搜索电台名称，例如 Jazz、新闻、BBC';
  static const search = '搜索';
  static const clear = '清除';
  static const refresh = '刷新';
  static const retry = '重试';

  static const allCountries = '全部国家';
  static const allLanguages = '全部语言';
  static const allTags = '全部标签';
  static const country = '国家';
  static const language = '语言';
  static const tag = '标签 / 流派';
  static const filterFailed = '筛选选项加载失败，已显示常用列表';

  static const popularEmpty = '没有找到电台';
  static const popularEmptyBody = '换一个关键词，或者放宽国家 / 语言 / 标签筛选。';
  static const favoritesEmpty = '还没有收藏电台';
  static const favoritesEmptyBody = '在热门列表里点小心心，收藏的电台会出现在这里。';
  static const customEmpty = '还没有自定义电台';
  static const customEmptyBody = '添加一个 http/https 流地址，或者直接粘贴 M3U / PLS 播放列表。';
  static const recentEmpty = '还没有播放过电台';
  static const recentEmptyBody = '点一个电台开始收听，最近播放会保留在这里。';

  static const loadFailed = '电台加载失败';
  static const loadMore = '加载更多';
  static const loadingMore = '正在加载…';
  static const noMore = '没有更多了';

  static const play = '播放';
  static const pause = '暂停';
  static const favorite = '收藏';
  static const unfavorite = '取消收藏';
  static const deleteCustom = '删除自定义电台';
  static const deleteTitle = '删除这个自定义电台？';
  static String deleteBody(String name) => '“$name”会从本机删除，收藏记录也会一起移除。';
  static const delete = '删除';
  static const cancel = '取消';

  static const addCustom = '添加自定义电台';
  static const addCustomShort = '添加电台';
  static const fieldName = '名称';
  static const fieldNameHint = '例如：我的爵士电台';
  static const fieldAddress = '流地址 / M3U / PLS';
  static const fieldAddressHint =
      'http:// 或 https:// 开头。也可以粘贴 M3U/PLS 文本，自动取第一条流地址。';
  static const fieldHomepage = '主页（可选）';
  static const fieldHomepageHint = 'https://example.com';
  static const parseAndSave = '解析并保存';
  static const saving = '正在保存…';
  static const addressRequired = '请粘贴流地址或 M3U/PLS 内容';
  static const added = '已添加自定义电台';
  static const deleted = '已删除自定义电台';

  static const started = '正在播放';
  static const played = '开始播放';
  static const favoriteDone = '已收藏';
  static const unfavoriteDone = '已取消收藏';
  static const actionFailed = '操作失败';
  static const networkHint = '公共 API 可能被网络环境拦截；会自动轮换 Radio Browser 镜像。';
}
