// Library health data layer (LIB-10 / LIB-11).
//
// * 重复组和健康条目都用 [PagedList]，只加载当前滚动窗口附近的页；
// * 扫描损坏文件是唯一会主动读源文件的调用，其它查询只读 SQLite。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';

/// 汇总卡：重复组、缺封面 / 歌词 / 标签、假无损、损坏文件。
final libraryHealthSummaryProvider =
    FutureProvider.autoDispose<LibraryHealthSummaryDto>((ref) async {
      ref.invalidateOnCatalogChange();
      ref.cacheFor(const Duration(seconds: 30));
      return core.libraryHealthSummary();
    });

/// 重复组分页列表。每页 20 组，最多缓存 10 页（LRU）。
final duplicateGroupListProvider =
    Provider.autoDispose<PagedList<DuplicateGroupDto>>((ref) {
      ref.invalidateOnCatalogChange();
      ref.cacheFor(const Duration(minutes: 2));
      final list = PagedList<DuplicateGroupDto>(
        pageSize: 20,
        maxCachedPages: 10,
        fetch: (offset, limit) =>
            core.duplicateGroups(offset: offset, limit: limit),
        count: () async => (await core.duplicateGroupCount()).toInt(),
      );
      ref.onDispose(list.dispose);
      return list;
    });

enum HealthTabKind {
  missingCover(HealthIssueKindDto.missingCover),
  missingLyrics(HealthIssueKindDto.missingLyrics),
  missingTags(HealthIssueKindDto.missingTags),
  fakeLossless(HealthIssueKindDto.fakeLossless),
  unreadable(HealthIssueKindDto.unreadable);

  const HealthTabKind(this.kind);

  final HealthIssueKindDto kind;

  String get label => switch (this) {
    HealthTabKind.missingCover => L10n.tr('缺封面', 'Missing Artwork'),
    HealthTabKind.missingLyrics => L10n.tr('缺歌词', 'Missing Lyrics'),
    HealthTabKind.missingTags => L10n.tr('无标签', 'Missing Tags'),
    HealthTabKind.fakeLossless => L10n.tr('疑似假无损', 'Suspected Fake Lossless'),
    HealthTabKind.unreadable => L10n.tr('损坏 / 不可读', 'Unreadable Files'),
  };
}

class HealthKindController extends Notifier<HealthTabKind> {
  @override
  HealthTabKind build() => HealthTabKind.missingCover;

  void set(HealthTabKind value) => state = value;
}

/// 当前选中的健康类别。
final healthKindProvider =
    NotifierProvider<HealthKindController, HealthTabKind>(
      HealthKindController.new,
    );

/// 某一类健康条目的分页列表。
final healthEntriesProvider = Provider.autoDispose
    .family<PagedList<LibraryHealthEntryDto>, HealthTabKind>((ref, tab) {
      ref.invalidateOnCatalogChange();
      ref.cacheFor(const Duration(minutes: 2));
      final list = PagedList<LibraryHealthEntryDto>(
        pageSize: 50,
        maxCachedPages: 10,
        fetch: (offset, limit) => core.libraryHealthPage(
          kind: tab.kind,
          offset: offset,
          limit: limit,
        ),
        count: () async =>
            (await core.libraryHealthCount(kind: tab.kind)).toInt(),
      );
      ref.onDispose(list.dispose);
      return list;
    });

/// 损坏文件扫描。失败时状态里保留错误，页面用 `AsyncValue` 显示。
class HealthScanController extends AsyncNotifier<LibraryHealthScanReportDto?> {
  @override
  Future<LibraryHealthScanReportDto?> build() async => null;

  /// 跑一次扫描；返回 `null` 表示失败（错误在 `state` 里）。
  Future<LibraryHealthScanReportDto?> scan() async {
    state = const AsyncLoading();
    final result = await AsyncValue.guard<LibraryHealthScanReportDto>(
      core.scanLibraryHealth,
    );
    state = result;
    if (result.hasValue) {
      ref.invalidate(libraryHealthSummaryProvider);
      ref.invalidate(duplicateGroupListProvider);
      ref.invalidate(healthEntriesProvider);
    }
    return result.value;
  }
}

final healthScanProvider =
    AsyncNotifierProvider<HealthScanController, LibraryHealthScanReportDto?>(
      HealthScanController.new,
    );
