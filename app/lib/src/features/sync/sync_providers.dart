// 多设备同步状态与操作（SYN-*）。
//
// 核心已经有 `sync_now(source_id)` 和 `CoreEvent::SyncStatus`；这里通过可替换的
// [SyncGateway] 把它们接到界面，方便 widget 测试不碰真实 FFI。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../bridge/core_events.dart';
import '../../l10n/app_l10n.dart';
import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';

/// 同步设置键名（保存在核心设置表里）。
abstract final class SyncSettingKeys {
  static const sourceId = 'sync.source_id';
  static const autoOnLaunch = 'sync.auto_on_launch';
  static const lastSummary = 'sync.last_summary';
}

/// 哪些音源类型能作为同步通道（和核心 `SourceKind::is_filesystem()` 保持一致）。
bool isSyncCapableSource(SourceKindDto kind) => switch (kind) {
  SourceKindDto.local ||
  SourceKindDto.smb ||
  SourceKindDto.webDav ||
  SourceKindDto.nfs ||
  SourceKindDto.sftp => true,
  _ => false,
};

/// 供 UI 与测试注入的同步接口。
abstract interface class SyncGateway {
  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);
  Future<SyncReportDto> syncNow(int sourceId);
}

class _CoreSyncGateway implements SyncGateway {
  const _CoreSyncGateway();

  @override
  Future<String?> getSetting(String key) => core.getSetting(key: key);

  @override
  Future<void> setSetting(String key, String value) =>
      core.setSetting(key: key, value: value);

  @override
  Future<SyncReportDto> syncNow(int sourceId) =>
      core.syncNow(sourceId: sourceId);
}

final syncGatewayProvider = Provider<SyncGateway>(
  (_) => const _CoreSyncGateway(),
);

@immutable
class SyncUiState {
  const SyncUiState({
    this.sourceId,
    this.autoOnLaunch = false,
    this.status = SyncStateDto.idle,
    this.busy = false,
    this.lastSummary,
    this.lastReport,
    this.error,
  });

  /// 选作同步通道的音源 ID；`null` 表示未启用。
  final int? sourceId;
  final bool autoOnLaunch;
  final SyncStateDto status;
  final bool busy;
  final String? lastSummary;
  final SyncReportDto? lastReport;
  final Object? error;

  SyncUiState copyWith({
    int? Function()? sourceId,
    bool? autoOnLaunch,
    SyncStateDto? status,
    bool? busy,
    String? Function()? lastSummary,
    SyncReportDto? Function()? lastReport,
    Object? Function()? error,
  }) => SyncUiState(
    sourceId: sourceId != null ? sourceId() : this.sourceId,
    autoOnLaunch: autoOnLaunch ?? this.autoOnLaunch,
    status: status ?? this.status,
    busy: busy ?? this.busy,
    lastSummary: lastSummary != null ? lastSummary() : this.lastSummary,
    lastReport: lastReport != null ? lastReport() : this.lastReport,
    error: error != null ? error() : this.error,
  );
}

final syncControllerProvider =
    AsyncNotifierProvider<SyncController, SyncUiState>(SyncController.new);

class SyncController extends AsyncNotifier<SyncUiState> {
  @override
  Future<SyncUiState> build() async {
    final gw = ref.watch(syncGatewayProvider);

    ref.listen<AsyncValue<CoreEventDto>>(coreEventsProvider, (_, next) {
      final ev = next.value;
      if (ev is CoreEventDto_SyncStatus) {
        final cur = state.value;
        if (cur != null) {
          state = AsyncData(cur.copyWith(status: ev.state));
        }
      }
    });

    final rawId = await gw.getSetting(SyncSettingKeys.sourceId);
    final rawAuto = await gw.getSetting(SyncSettingKeys.autoOnLaunch);
    final lastSummary = await gw.getSetting(SyncSettingKeys.lastSummary);
    return SyncUiState(
      sourceId: rawId == null || rawId.isEmpty ? null : int.tryParse(rawId),
      autoOnLaunch: rawAuto == 'true',
      lastSummary: lastSummary == null || lastSummary.isEmpty
          ? null
          : lastSummary,
    );
  }

  Future<void> setSourceId(int? sourceId) async {
    final gw = ref.read(syncGatewayProvider);
    final cur = state.value ?? const SyncUiState();
    state = AsyncData(
      cur.copyWith(sourceId: () => sourceId, error: () => null),
    );
    await gw.setSetting(
      SyncSettingKeys.sourceId,
      sourceId == null ? '' : '$sourceId',
    );
  }

  Future<void> setAutoOnLaunch(bool enabled) async {
    final gw = ref.read(syncGatewayProvider);
    final cur = state.value ?? const SyncUiState();
    state = AsyncData(cur.copyWith(autoOnLaunch: enabled));
    await gw.setSetting(
      SyncSettingKeys.autoOnLaunch,
      enabled ? 'true' : 'false',
    );
  }

  Future<SyncReportDto?> syncNow() async {
    final cur = state.value;
    final id = cur?.sourceId;
    if (cur == null || id == null || cur.busy) return null;
    final gw = ref.read(syncGatewayProvider);
    state = AsyncData(
      cur.copyWith(busy: true, status: SyncStateDto.syncing, error: () => null),
    );
    try {
      final report = await gw.syncNow(id);
      final now = DateTime.now();
      final stamp =
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
      final summary = L10n.tr(
        '$stamp · 推送 ${report.pushed} / 拉取 ${report.pulled} / 应用 ${report.applied}',
        '$stamp · Pushed ${report.pushed} / Pulled ${report.pulled} / Applied ${report.applied}',
      );
      await gw.setSetting(SyncSettingKeys.lastSummary, summary);
      state = AsyncData(
        (state.value ?? cur).copyWith(
          busy: false,
          status: SyncStateDto.idle,
          lastReport: () => report,
          lastSummary: () => summary,
          error: () => null,
        ),
      );
      return report;
    } catch (e) {
      state = AsyncData(
        (state.value ?? cur).copyWith(
          busy: false,
          status: SyncStateDto.unavailable,
          error: () => e,
        ),
      );
      return null;
    }
  }
}
