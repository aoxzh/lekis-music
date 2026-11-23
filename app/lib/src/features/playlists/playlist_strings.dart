// 歌单（普通 / 智能 / M3U 导入导出）页面的全部双语文案。

import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/l10n/duration_text.dart';

String _songs(int n) => n == 1 ? '1 song' : '$n songs';
String _entries(int n) => n == 1 ? '1 entry' : '$n entries';
String _paths(int n) => n == 1 ? '1 path' : '$n paths';

abstract final class PlaylistStrings {
  // 通用按钮
  static String get ok => L10n.tr('确定', 'OK');
  static String get cancel => L10n.tr('取消', 'Cancel');
  static String get save => L10n.tr('保存', 'Save');
  static String get delete => L10n.tr('删除', 'Delete');
  static String get create => L10n.tr('创建', 'Create');
  static String get close => L10n.tr('关闭', 'Close');
  static String get open => L10n.tr('打开', 'Open');
  static String get rename => L10n.tr('重命名', 'Rename');
  static String get retry => L10n.tr('重试', 'Retry');
  static String get play => L10n.tr('播放', 'Play');

  // 名称对话框 / 增删改
  static String get nameLabel => L10n.tr('歌单名称', 'Playlist name');
  static String get nameEmpty => L10n.tr('名称不能为空', 'Name can\'t be empty');
  static String get deleteTitle => L10n.tr('删除歌单？', 'Delete playlist?');
  static String deleteSmartBody(String name) => L10n.tr(
    '“$name”和它的规则会被删除，曲目文件不受影响。',
    '"$name" and its rules will be deleted. Your music files are not affected.',
  );
  static String deleteBody(String name) => L10n.tr(
    '“$name”会被删除，曲目文件不受影响。',
    '"$name" will be deleted. Your music files are not affected.',
  );
  static String actionFailed(String e) =>
      L10n.tr('操作失败：$e', 'Action failed: $e');
  static String deleted(String name) =>
      L10n.tr('已删除“$name”', 'Deleted "$name"');
  static String get renameTitle => L10n.tr('重命名歌单', 'Rename Playlist');
  static String get duplicate => L10n.tr('复制歌单', 'Duplicate Playlist');
  static String get duplicateTitle => L10n.tr('复制为歌单', 'Duplicate as Playlist');
  static String duplicateName(String name) => L10n.tr('$name 副本', '$name copy');
  static String get duplicating => L10n.tr('正在复制歌单', 'Duplicating Playlist');
  static String duplicated(String name, int count) =>
      L10n.tr('已复制 $count 首到「$name」', 'Copied $count tracks to "$name"');
  static String duplicatedSmart(String name) =>
      L10n.tr('已复制智能歌单「$name」', 'Copied smart playlist "$name"');
  static String get duplicateSmartUnsupported => L10n.tr(
    '智能歌单不能直接复制为普通歌单',
    'Smart playlists cannot be duplicated as regular playlists',
  );
  static String get copyPlaylist => L10n.tr('复制歌单', 'Copy Playlist');
  static String copiedPlaylist(int n) =>
      L10n.tr('已复制歌单（$n 首）', 'Copied $n playlist tracks');
  static String get nothingToCopy =>
      L10n.tr('歌单里没有可复制的曲目', 'No tracks to copy');
  static String copyPlaylistFailed(String e) =>
      L10n.tr('复制歌单失败：$e', 'Failed to copy playlist: $e');
  static String get copyTrackList => L10n.tr('复制曲目列表', 'Copy Track List');
  static String copiedTrackList(int n) =>
      L10n.tr('已复制曲目列表（$n 首）', 'Copied $n tracks');
  static String get noTracksToCopy => L10n.tr('没有可复制的曲目', 'No tracks to copy');
  static String copyTracksFailed(String e) =>
      L10n.tr('复制失败：$e', 'Failed to copy: $e');
  static String get removeDuplicates => L10n.tr('移除重复曲目', 'Remove Duplicates');
  static String get removeDuplicatesTitle =>
      L10n.tr('移除重复曲目？', 'Remove Duplicate Tracks?');
  static String removeDuplicatesBody(int count) => L10n.tr(
    '将移除 $count 个重复条目，每个曲目保留第一次出现。',
    'This removes $count duplicate entries, keeping the first occurrence of each track.',
  );
  static String get removingDuplicates =>
      L10n.tr('正在移除重复曲目', 'Removing Duplicates');
  static String duplicatesRemoved(int removed, int failed) => failed == 0
      ? L10n.tr('已移除 $removed 个重复条目', 'Removed $removed duplicate entries')
      : L10n.tr(
          '已移除 $removed 个，$failed 个失败',
          'Removed $removed; $failed failed',
        );
  static String get noDuplicates => L10n.tr('没有重复曲目', 'No duplicate tracks');
  static String get sortPlaylist => L10n.tr('排序歌单', 'Sort Playlist');
  static String get sortByTitle => L10n.tr('按标题', 'By Title');
  static String get sortByArtist => L10n.tr('按艺人', 'By Artist');
  static String get sortByAlbum => L10n.tr('按专辑', 'By Album');
  static String get sortByAdded => L10n.tr('按添加时间', 'By Date Added');
  static String get sortByDuration => L10n.tr('按时长', 'By Duration');
  static String get reverseOrder => L10n.tr('反转顺序', 'Reverse Order');
  static String get shuffleOrder => L10n.tr('随机顺序', 'Shuffle Order');
  static String get searchPlaylist => L10n.tr('搜索歌单', 'Search playlist');
  static String get clearSearch => L10n.tr('清除', 'Clear');
  static String get noMatchingTracks => L10n.tr('没有匹配的歌曲', 'No matching songs');
  static String get sortConfirmTitle => L10n.tr('排序歌单？', 'Sort Playlist?');
  static String sortConfirmBody(String label) => L10n.tr(
    '将按「$label」重新排列并保存顺序。',
    'This reorders and saves the playlist by $label.',
  );
  static String get sortingPlaylist => L10n.tr('正在排序歌单', 'Sorting Playlist');
  static String get sortedPlaylist => L10n.tr('歌单已排序', 'Playlist sorted');
  static String sortPartial(int failed) =>
      L10n.tr('排序完成，$failed 首移动失败', 'Sorted with $failed failed moves');
  static String get nothingToSort => L10n.tr('没有可排序的曲目', 'No tracks to sort');
  static String get alreadySorted =>
      L10n.tr('歌单已经是这个顺序', 'Playlist is already in this order');
  static String get smartSubtitle =>
      L10n.tr('智能歌单 · 规则实时求值', 'Smart playlist · live rules');
  static String songCount(int n) => L10n.tr('$n 首歌曲', _songs(n));
  static String get kindSmart => L10n.tr('智能', 'Smart');
  static String get kindPlaylist => L10n.tr('歌单', 'Playlist');

  // 添加到歌单
  static String createdAndAdded(String name) =>
      L10n.tr('已新建“$name”并添加', 'Created "$name" and added');
  static String addedTo(String name) =>
      L10n.tr('已添加到“$name”', 'Added to "$name"');
  static String alreadyIn(String name) =>
      L10n.tr('“$name”里已经有这首歌了', 'Already in "$name"');
  static String addFailed(String e) => L10n.tr('添加失败：$e', 'Couldn\'t add: $e');
  static String createFailed(String e) =>
      L10n.tr('创建失败：$e', 'Couldn\'t create: $e');
  static String loadFailed(String e) =>
      L10n.tr('加载失败：$e', 'Couldn\'t load: $e');
  static String get newPlaylist => L10n.tr('新建歌单', 'New Playlist');
  static String get newSmartPlaylist => L10n.tr('新建智能歌单', 'New Smart Playlist');
  static String get createAndAdd => L10n.tr('创建并添加', 'Create & Add');
  static String get addToPlaylist => L10n.tr('添加到歌单', 'Add to Playlist');
  static String get newShort => L10n.tr('新建', 'New');
  static String get noPlaylistsCreate =>
      L10n.tr('还没有歌单，先新建一个吧', 'No playlists yet — create one first');
  static String get smartNotAddable => L10n.tr(
    '智能歌单由规则管理，不能手动添加',
    'Smart playlists are rule-based; can\'t add manually',
  );

  // 歌单列表
  static String get myPlaylists => L10n.tr('我的歌单', 'My Playlists');
  static String get importPlaylist => L10n.tr('导入歌单', 'Import Playlist');
  static String get listLoadFailed =>
      L10n.tr('歌单加载失败', 'Couldn\'t load playlists');
  static String get playlistActions => L10n.tr('歌单操作', 'Playlist actions');
  static String get editRules => L10n.tr('编辑规则', 'Edit Rules');
  static String get emptyTitle => L10n.tr('还没有歌单', 'No playlists yet');
  static String get emptyMessage => L10n.tr(
    '新建普通歌单，或者用规则建一个智能歌单',
    'Create a playlist, or build a smart one from rules',
  );

  // 歌单详情
  static String playlistLoadFailed(String e) =>
      L10n.tr('歌单加载失败：$e', 'Couldn\'t load playlist: $e');
  static String detailSubtitle(int n, {Duration? total}) {
    if (total == null || total.inSeconds <= 0) {
      return L10n.tr('$n 首 · 可上下移动条目', '${_songs(n)} · reorder with up/down');
    }
    return '${L10n.tr('$n 首', _songs(n))} · ${formatTotalDuration(total)}';
  }

  static String entriesLoadFailed(String e) =>
      L10n.tr('条目加载失败：$e', 'Couldn\'t load entries: $e');
  static String smartMatched(int n, bool capped) => L10n.tr(
    '智能歌单 · 已匹配 $n${capped ? '+' : ''} 首',
    'Smart playlist · $n${capped ? '+' : ''} ${n == 1 && !capped ? 'match' : 'matches'}',
  );
  static String rulesEvalFailed(String e) =>
      L10n.tr('规则求值失败：$e', 'Couldn\'t evaluate rules: $e');
  static String get downloadPlaylist => L10n.tr('下载歌单', 'Download');
  static String get exportPlaylist => L10n.tr('导出歌单', 'Export Playlist');
  static String get deletePlaylist => L10n.tr('删除歌单', 'Delete Playlist');
  static String get trackUnavailable =>
      L10n.tr('（曲目暂时不可用）', '(Track unavailable)');
  static String get moveUp => L10n.tr('上移', 'Move Up');
  static String get moveDown => L10n.tr('下移', 'Move Down');
  static String get moveToTop => L10n.tr('移到顶部', 'Move to Top');
  static String get moveToBottom => L10n.tr('移到底部', 'Move to Bottom');
  static String get entryActions => L10n.tr('条目操作', 'Entry actions');
  static String get removeFromPlaylist =>
      L10n.tr('从歌单移除', 'Remove from Playlist');
  static String get smartEmpty =>
      L10n.tr('规则还没有匹配到歌曲', 'No songs match these rules yet');
  static String get staticEmpty => L10n.tr(
    '歌单是空的，从歌曲行菜单里添加',
    'This playlist is empty — add songs from a song\'s menu',
  );

  // M3U / XSPF 导入导出
  static String importSummaryEmpty() => L10n.tr(
    '文件里没有条目，已创建空歌单。',
    'No entries in the file; created an empty playlist.',
  );
  static String importSummaryAll(int matched, int total) => L10n.tr(
    '已导入 $matched 首歌曲（共 $total 条）。',
    'Imported ${_songs(matched)} (of ${_entries(total)}).',
  );
  static String importSummaryPartial(
    int matched,
    int missing,
    int total,
  ) => L10n.tr(
    '已导入 $matched 首歌曲，$missing 个路径未匹配（共 $total 条）。',
    'Imported ${_songs(matched)}; ${_paths(missing)} not matched (of ${_entries(total)}).',
  );
  static String get importedName => L10n.tr('导入的歌单', 'Imported Playlist');
  static String get smartNotExportable => L10n.tr(
    '智能歌单没有固定条目，不能导出',
    'Smart playlists have no fixed entries and can\'t be exported',
  );
  static String get m3uSubtitle =>
      L10n.tr('兼容大多数播放器、车载和 NAS', 'Works with most players, cars and NAS');
  static String get xspfSubtitle => L10n.tr(
    'XML 格式，保留艺人和标题元数据',
    'XML format; keeps artist and title metadata',
  );
  static String exportFormat(String format) =>
      L10n.tr('导出 $format', 'Export $format');
  static String exportCount(String name, int n) =>
      L10n.tr('“$name”共 $n 个条目。', '"$name" has ${_entries(n)}.');
  static String get m3uExportHint => L10n.tr(
    '文件是 UTF-8 编码的 .m3u8，可以复制后粘贴到别处，或直接保存到设备。',
    'A UTF-8 .m3u8 file. Copy and paste it elsewhere, or save it to this device.',
  );
  static String get xspfExportHint => L10n.tr(
    '文件是 UTF-8 编码的 .xspf（XML），适合保留艺人/标题并导入其他播放器。',
    'A UTF-8 .xspf (XML) file that keeps artist/title for importing into other players.',
  );
  static String get copy => L10n.tr('复制', 'Copy');
  static String get saveFile => L10n.tr('保存文件', 'Save File');
  static String copied(String format, int n) =>
      L10n.tr('已复制 $format 文本（$n 个条目）', 'Copied $format text (${_entries(n)})');
  static String saved(String fileName) =>
      L10n.tr('已保存 $fileName', 'Saved $fileName');
  static String saveFailed(Object e) => L10n.tr('保存失败：$e', 'Save failed: $e');
  static String get pickPlaylistFile =>
      L10n.tr('选择播放列表', 'Choose a playlist file');
  static String readFileFailed(Object e) =>
      L10n.tr('读取文件失败：$e', 'Couldn\'t read file: $e');
  static String get importNoContent =>
      L10n.tr('请选择歌单文件或粘贴内容', 'Choose a playlist file or paste its contents');
  static String get chooseFile => L10n.tr('选择文件', 'Choose File');
  static String get pasteFromClipboard =>
      L10n.tr('从剪贴板粘贴', 'Paste from Clipboard');
  static String get importHint => L10n.tr(
    '把 .m3u / .m3u8 / .xspf 的内容粘贴到这里，或者点上面的“选择文件”',
    'Paste .m3u / .m3u8 / .xspf contents here, or tap "Choose File" above',
  );
  static String get importing => L10n.tr('导入中…', 'Importing…');
  static String get import => L10n.tr('导入', 'Import');
  static String get importDone => L10n.tr('导入完成', 'Import Complete');
  static String importCounts(int matched, int unmatched) => L10n.tr(
    '匹配 $matched 首 · 未匹配 $unmatched 个',
    '$matched matched · $unmatched unmatched',
  );
  static String get unmatchedPaths => L10n.tr('未匹配的路径', 'Unmatched paths');
  static String get openPlaylist => L10n.tr('打开歌单', 'Open Playlist');

  // 智能歌单编辑器
  static String get smartRulesTitle =>
      L10n.tr('智能歌单规则', 'Smart Playlist Rules');
  static String rulesLoadFailed(Object e) =>
      L10n.tr('规则加载失败：$e', 'Couldn\'t load rules: $e');
  static String get rulesIntro => L10n.tr(
    '条件在核心里实时求值；同一分组内 AND / OR 可以任意嵌套。',
    'Rules are evaluated live. AND / OR groups can be nested freely.',
  );
  static String get saveRules => L10n.tr('保存规则', 'Save Rules');
  static String get condition => L10n.tr('条件', 'Condition');
  static String get not => L10n.tr('取反（NOT）', 'Negate (NOT)');
  static String get matchAll => L10n.tr('全部满足 AND', 'Match all (AND)');
  static String get matchAny => L10n.tr('任意满足 OR', 'Match any (OR)');
  static String get deleteGroup => L10n.tr('删除分组', 'Delete group');
  static String get emptyOr =>
      L10n.tr('空 OR 组匹配不到任何歌曲', 'An empty OR group matches nothing');
  static String get emptyAnd =>
      L10n.tr('空 AND 组不过滤（匹配全部歌曲）', 'An empty AND group matches all songs');
  static String get addCondition => L10n.tr('添加条件', 'Add Condition');
  static String get addOrGroup => L10n.tr('添加 OR 分组', 'Add OR Group');
  static String get anyHolds =>
      L10n.tr('组内任意一条成立即可', 'Any condition in the group must match');
  static String get allHold =>
      L10n.tr('组内全部条件都要成立', 'All conditions in the group must match');
  static String get field => L10n.tr('字段', 'Field');
  static String get deleteCondition => L10n.tr('删除条件', 'Delete condition');
  static String get value => L10n.tr('值', 'Value');
  static String get valueList => L10n.tr('值（逗号分隔）', 'Values (comma-separated)');
  static String get yes => L10n.tr('是', 'Yes');
  static String get no => L10n.tr('否', 'No');
  static String get min => L10n.tr('最小值', 'Min');
  static String get max => L10n.tr('最大值', 'Max');
  static String get otherSettings => L10n.tr('其他设置', 'Other Settings');
  static String get limitLabel => L10n.tr(
    '最多多少首（留空 = 不限，最大 5000）',
    'Max songs (blank = no limit, up to 5000)',
  );
  static String get sort => L10n.tr('排序', 'Sort');
  static String get sortDefault => L10n.tr('默认', 'Default');
  static String get descending => L10n.tr('倒序', 'Descending');
  static String moreSongs(int n) =>
      L10n.tr('还有 $n 首…', n == 1 ? '1 more song…' : '$n more songs…');
  static String rulesInvalid(String e) =>
      L10n.tr('规则无效：$e', 'Invalid rules: $e');
  static String get previewing => L10n.tr('正在预览…', 'Previewing…');
  static String previewCount(int n) =>
      L10n.tr('预览：匹配 $n 首', 'Preview: ${n == 1 ? '1 match' : '$n matches'}');
}
