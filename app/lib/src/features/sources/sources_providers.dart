// 音源相关的状态：配置列表（来自核心）+ 运行时状态（扫描进度、可达性，来自事件流）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../bridge/core_events.dart';
import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';
import '../../rust/api/error.dart';
import 'common.dart';
import 'source_credentials.dart';
import 'source_draft.dart';
import 'source_gateway.dart';

/// 已配置的全部音源。音源变化（`LibraryChanged(sources)`）时自动重新读取。
final sourcesProvider =
    AsyncNotifierProvider<SourcesNotifier, List<SourceConfigDto>>(
      SourcesNotifier.new,
    );

class SourcesNotifier extends AsyncNotifier<List<SourceConfigDto>> {
  @override
  Future<List<SourceConfigDto>> build() {
    ref.listen(coreEventsProvider, (_, next) {
      final event = next.value;
      if (event is CoreEventDto_LibraryChanged &&
          event.scope == LibraryScopeDto.sources) {
        ref.invalidateSelf();
      }
    });
    return core.listSources();
  }

  Future<void> reload() async {
    state = await AsyncValue.guard(core.listSources);
  }
}

/// 核心持久化的扫描记录（上次扫描时间、失败原因），按音源 ID 索引。
/// 扫描结束、音源变化时重新读取。
final sourceScanHistoryProvider = FutureProvider<Map<int, SourceInfoDto>>((
  ref,
) async {
  ref.listen(coreEventsProvider, (_, next) {
    final event = next.value;
    final refresh = switch (event) {
      CoreEventDto_ScanFinished() => true,
      CoreEventDto_SourceReachability(:final reachable) => !reachable,
      CoreEventDto_LibraryChanged(:final scope) =>
        scope == LibraryScopeDto.sources,
      _ => false,
    };
    if (refresh) ref.invalidateSelf();
  });
  final infos = await core.listSourceInfos();
  return {
    for (final i in infos)
      if (i.config.id case final id?) id.toInt(): i,
  };
});

/// 本次启动里看到的最近一次扫描结果（带增删统计）。重启前的记录见
/// [sourceScanHistoryProvider]。
@immutable
class ScanSummary {
  const ScanSummary({
    required this.finishedAt,
    required this.added,
    required this.updated,
    required this.removed,
  });

  final DateTime finishedAt;
  final int added;
  final int updated;
  final int removed;
}

/// 一个音源的运行时状态。
@immutable
class SourceRuntime {
  const SourceRuntime({
    this.scanning = false,
    this.phase,
    this.done = 0,
    this.total,
    this.scanStartedAt,
    this.lastScan,
    this.reachable,
    this.lastError,
  });

  /// 正在扫描（包括已经发起、还没收到第一条进度的阶段）。
  final bool scanning;
  final ScanPhaseDto? phase;
  final int done;
  final int? total;

  /// 当前阶段有总数后开始计时，用于估算剩余时间。
  final DateTime? scanStartedAt;
  final ScanSummary? lastScan;

  /// `null` 表示还没有探测结果。
  final bool? reachable;

  /// 最近一次操作失败的原因（核心错误）。
  final Object? lastError;

  /// 0..1 的进度；总数未知时为 `null`（不确定进度条）。
  double? get fraction {
    final t = total;
    if (t == null || t == 0) return null;
    return (done / t).clamp(0.0, 1.0);
  }

  /// 按当前阶段的平均速度估算剩余时间；样本太少或总数未知时为 `null`。
  Duration? get eta {
    final t = total;
    final start = scanStartedAt;
    if (t == null || t <= 0 || start == null || done <= 0) return null;
    final elapsed = DateTime.now().difference(start).inMilliseconds;
    if (elapsed < 1500) return null;
    final remaining = t - done;
    if (remaining <= 0) return null;
    return Duration(milliseconds: (elapsed * remaining / done).round());
  }

  SourceRuntime copyWith({
    bool? scanning,
    ScanPhaseDto? phase,
    int? done,
    int? total,
    DateTime? scanStartedAt,
    ScanSummary? lastScan,
    bool? reachable,
    Object? lastError,
    bool clearPhase = false,
    bool clearScanStartedAt = false,
    bool clearError = false,
  }) => SourceRuntime(
    scanning: scanning ?? this.scanning,
    phase: clearPhase ? null : (phase ?? this.phase),
    done: done ?? this.done,
    total: clearPhase ? null : (total ?? this.total),
    scanStartedAt: clearScanStartedAt
        ? null
        : (scanStartedAt ?? this.scanStartedAt),
    lastScan: lastScan ?? this.lastScan,
    reachable: reachable ?? this.reachable,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );
}

/// 每个音源的运行时状态，按音源 ID 索引。
final sourceRuntimeProvider =
    NotifierProvider<SourceRuntimeNotifier, Map<int, SourceRuntime>>(
      SourceRuntimeNotifier.new,
    );

class SourceRuntimeNotifier extends Notifier<Map<int, SourceRuntime>> {
  @override
  Map<int, SourceRuntime> build() {
    ref.listen(coreEventsProvider, (_, next) {
      final event = next.value;
      if (event != null) _onEvent(event);
    });
    return const {};
  }

  SourceRuntime _get(int id) => state[id] ?? const SourceRuntime();

  void _put(int id, SourceRuntime value) => state = {...state, id: value};

  void _onEvent(CoreEventDto event) {
    switch (event) {
      case CoreEventDto_ScanProgress(
        :final sourceId,
        :final phase,
        :final done,
        :final total,
      ):
        final before = _get(sourceId);
        if (before.reachable != true) {
          // 能收到进度说明连上了，顺手告诉核心，让它调整选源顺序。
          core.reportSourceReachability(sourceId: sourceId, reachable: true);
        }
        final totalInt = total?.toInt();
        final samePhase = before.phase == phase && before.total == totalInt;
        final startedAt = totalInt == null
            ? null
            : samePhase
            ? before.scanStartedAt
            : DateTime.now();
        _put(
          sourceId,
          before.copyWith(
            scanning: true,
            phase: phase,
            done: done.toInt(),
            total: totalInt,
            scanStartedAt: startedAt,
            clearScanStartedAt: totalInt == null,
            reachable: true,
            clearError: true,
          ),
        );
      case CoreEventDto_ScanFinished(
        :final sourceId,
        :final added,
        :final updated,
        :final removed,
      ):
        _put(
          sourceId,
          SourceRuntime(
            reachable: true,
            lastScan: ScanSummary(
              finishedAt: DateTime.now(),
              added: added.toInt(),
              updated: updated.toInt(),
              removed: removed.toInt(),
            ),
          ),
        );
      case CoreEventDto_SourceReachability(:final sourceId, :final reachable):
        final before = _get(sourceId);
        _put(
          sourceId,
          // 服务器源同步失败时核心只发这条事件，所以不可达也意味着扫描结束了。
          reachable
              ? before.copyWith(reachable: true)
              : before.copyWith(
                  reachable: false,
                  scanning: false,
                  clearPhase: true,
                  clearScanStartedAt: true,
                ),
        );
      default:
        break;
    }
  }

  void markScanStarting(int id) => _put(
    id,
    _get(id).copyWith(
      scanning: true,
      done: 0,
      clearPhase: true,
      clearScanStartedAt: true,
      clearError: true,
    ),
  );

  void markFailed(int id, Object error) {
    final unreachable = coreErrorKind(error) == ErrorKind.network;
    _put(
      id,
      _get(id).copyWith(
        scanning: false,
        clearPhase: true,
        clearScanStartedAt: true,
        lastError: error,
        reachable: unreachable ? false : null,
      ),
    );
  }
}

/// 添加音源的结果。`scanError` 非空表示音源已保存，但第一次扫描没能开始。
@immutable
class AddSourceResult {
  const AddSourceResult(this.sourceId, {this.scanError});
  final int sourceId;
  final Object? scanError;
}

/// 音源相关的操作。界面只调用这里，不直接碰核心。
final sourceActionsProvider = Provider<SourceActions>(SourceActions.new);

class SourceActions {
  SourceActions(this._ref, {SourceGateway gateway = const CoreSourceGateway()})
    : _credentials = SourceCredentialService(gateway);

  final Ref _ref;
  final SourceCredentialService _credentials;

  /// 保存音源并立即开始第一次扫描。保存失败时抛出核心错误。
  ///
  /// 密码先按 `credential_ref` 写进核心的凭据库，地址 / options / 数据库里
  /// 只留下引用。扫描失败时音源仍会留在列表里。
  Future<AddSourceResult> add(SourceDraft draft) async {
    final id = await _credentials.add(draft);
    _ref.invalidate(sourcesProvider);
    try {
      await rescan(id);
      return AddSourceResult(id);
    } catch (e) {
      return AddSourceResult(id, scanError: e);
    }
  }

  /// 修改音源。没填新密码时沿用已保存的凭据。
  Future<void> update(SourceConfigDto existing, SourceDraft draft) async {
    await _credentials.update(existing, draft);
    _ref.invalidate(sourcesProvider);
  }

  /// 删除音源和它的凭据（凭据清理失败时返回 `false`，音源已经删除）。
  Future<bool> delete(SourceConfigDto source) async {
    final cleaned = await _credentials.delete(source);
    _ref.invalidate(sourcesProvider);
    return cleaned;
  }

  /// 测试一个已保存的音源，不扫描、不写库。
  Future<void> test(SourceConfigDto source) => _credentials.test(source);

  /// 测试表单里的未保存配置；临时凭据测完即删。
  Future<void> testDraft(SourceDraft draft, {SourceConfigDto? existing}) =>
      _credentials.testDraft(draft, existing: existing);

  /// 列出草稿主机上的 SMB 共享 / NFS 导出。临时凭据用完即删。
  Future<List<ShareDto>> listShares(
    SourceDraft draft, {
    SourceConfigDto? existing,
  }) => _credentials.listShares(draft, existing: existing);

  /// 浏览草稿配置里 `path` 下的子文件夹。临时凭据用完即删。
  Future<SourceListingDto> browse(
    SourceDraft draft,
    String path, {
    SourceConfigDto? existing,
  }) => _credentials.browse(draft, path, existing: existing);

  /// 用草稿拼一次配置，供文件夹浏览器连续浏览（临时凭据只写一次）。
  Future<T> withPreparedConfig<T>(
    SourceDraft draft,
    Future<T> Function(SourceConfigDto config) body, {
    SourceConfigDto? existing,
  }) => _credentials.withPreparedConfig(draft, body, existing: existing);

  /// 用准备好的配置浏览子文件夹（配合 [withPreparedConfig]）。
  Future<SourceListingDto> browseConfig(SourceConfigDto config, String path) =>
      _credentials.browseConfig(config, path);

  /// 某个凭据引用是否已保存（编辑表单判断要不要重新输入密码）。
  bool hasCredential(String credentialRef) =>
      _credentials.hasCredential(credentialRef);

  /// 重新扫描一个音源。失败时抛出核心错误（同时记进运行时状态）。
  Future<void> rescan(int id) async {
    final runtime = _ref.read(sourceRuntimeProvider.notifier);
    runtime.markScanStarting(id);
    try {
      await core.startScan(sourceId: id);
    } catch (e) {
      runtime.markFailed(id, e);
      if (coreErrorKind(e) == ErrorKind.network) {
        core.reportSourceReachability(sourceId: id, reachable: false);
      }
      rethrow;
    }
  }

  /// 用这个文件系统音源跑一轮跨设备同步。
  Future<SyncReportDto> syncNow(int id) => core.syncNow(sourceId: id);
}
