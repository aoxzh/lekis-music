// 应用在线更新状态机（Riverpod）。
//
// 桌面端参考 yetone/magpie：后台静默检查 → 发现新版本 → 应用内流式下载（带进度与速度）
// → SHA-256 校验 → 解压暂存 → 一键重启替换并自动拉起新版。
// 移动端或只读安装目录自动回退为直接打开下载链接。

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_updater.dart';
import 'desktop_self_updater.dart';

enum AppUpdaterPhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  restarting,
  error,
}

class AppUpdaterState {
  const AppUpdaterState({
    this.phase = AppUpdaterPhase.idle,
    this.info,
    this.progress,
    this.staged,
    this.capability,
    this.errorMessage,
    this.currentVersion = kLekisAppVersion,
  });

  final AppUpdaterPhase phase;
  final AppUpdateInfo? info;
  final UpdateDownloadProgress? progress;
  final StagedDesktopUpdate? staged;
  final SelfUpdateCapability? capability;
  final String? errorMessage;
  final String currentVersion;

  bool get canInAppUpdate =>
      capability?.supported == true && info?.assetName != null;

  AppUpdaterState copyWith({
    AppUpdaterPhase? phase,
    AppUpdateInfo? info,
    UpdateDownloadProgress? progress,
    bool clearProgress = false,
    StagedDesktopUpdate? staged,
    bool clearStaged = false,
    SelfUpdateCapability? capability,
    String? errorMessage,
    bool clearError = false,
    String? currentVersion,
  }) => AppUpdaterState(
    phase: phase ?? this.phase,
    info: info ?? this.info,
    progress: clearProgress ? null : (progress ?? this.progress),
    staged: clearStaged ? null : (staged ?? this.staged),
    capability: capability ?? this.capability,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    currentVersion: currentVersion ?? this.currentVersion,
  );
}

final appUpdaterProvider =
    NotifierProvider<AppUpdaterNotifier, AppUpdaterState>(
      AppUpdaterNotifier.new,
    );

class AppUpdaterNotifier extends Notifier<AppUpdaterState> {
  UpdateCancelToken? _cancelToken;
  DateTime? _lastCheckedAt;

  @override
  AppUpdaterState build() => const AppUpdaterState();

  /// Checks GitHub Releases for a newer version.
  ///
  /// When [silent] is true (e.g. startup background check), errors and
  /// up-to-date states do not disturb the user, and checks are throttled to
  /// once every 6 hours.
  Future<AppUpdateCheckResult?> checkForUpdates({bool silent = false}) async {
    if (state.phase == AppUpdaterPhase.checking ||
        state.phase == AppUpdaterPhase.downloading ||
        state.phase == AppUpdaterPhase.restarting) {
      return null;
    }
    // If an update is already staged and ready to apply, keep it ready unless
    // the user explicitly checks again.
    if (silent && state.phase == AppUpdaterPhase.ready) {
      return null;
    }
    if (silent &&
        _lastCheckedAt != null &&
        DateTime.now().difference(_lastCheckedAt!) < const Duration(hours: 6)) {
      return null;
    }

    if (!silent) {
      state = state.copyWith(
        phase: AppUpdaterPhase.checking,
        clearError: true,
      );
    }

    final result = await checkForAppUpdate();
    _lastCheckedAt = DateTime.now();

    switch (result) {
      case AppUpdateUpToDate(:final currentVersion):
        if (!silent) {
          state = state.copyWith(
            phase: AppUpdaterPhase.upToDate,
            currentVersion: currentVersion,
            clearError: true,
          );
        }
      case AppUpdateError(:final message):
        if (!silent) {
          state = state.copyWith(
            phase: AppUpdaterPhase.error,
            errorMessage: message,
          );
        }
      case AppUpdateAvailable(:final info):
        final capability = checkSelfUpdateCapability();
        // If we already staged this exact version, stay in `ready`.
        if (state.staged != null && state.staged!.version == info.version) {
          state = state.copyWith(
            phase: AppUpdaterPhase.ready,
            info: info,
            capability: capability,
            clearError: true,
          );
        } else {
          state = state.copyWith(
            phase: AppUpdaterPhase.available,
            info: info,
            capability: capability,
            clearProgress: true,
            clearStaged: true,
            clearError: true,
          );
        }
    }
    return result;
  }

  /// Downloads, SHA-256 verifies, and stages the pending desktop update.
  Future<void> downloadAndStage() async {
    final info = state.info;
    final capability = state.capability ?? checkSelfUpdateCapability();
    if (info == null || !capability.supported) return;
    if (state.phase == AppUpdaterPhase.downloading ||
        state.phase == AppUpdaterPhase.restarting) {
      return;
    }

    final token = UpdateCancelToken();
    _cancelToken = token;
    state = state.copyWith(
      phase: AppUpdaterPhase.downloading,
      capability: capability,
      progress: UpdateDownloadProgress(
        step: UpdateStep.downloading,
        receivedBytes: 0,
        totalBytes: info.assetSize ?? 0,
      ),
      clearError: true,
    );

    try {
      final staged = await downloadAndStageDesktopUpdate(
        info,
        capability: capability,
        cancelToken: token,
        onProgress: (p) {
          if (_cancelToken == token && !token.isCancelled) {
            state = state.copyWith(progress: p);
          }
        },
      );
      if (_cancelToken == token && !token.isCancelled) {
        _cancelToken = null;
        state = state.copyWith(
          phase: AppUpdaterPhase.ready,
          staged: staged,
          clearProgress: true,
          clearError: true,
        );
      }
    } on UpdateCancelledException {
      if (_cancelToken == token) _cancelToken = null;
      state = state.copyWith(
        phase: AppUpdaterPhase.available,
        clearProgress: true,
        clearError: true,
      );
    } catch (e) {
      if (_cancelToken == token) _cancelToken = null;
      state = state.copyWith(
        phase: AppUpdaterPhase.error,
        errorMessage: e.toString(),
        clearProgress: true,
      );
    }
  }

  void cancelDownload() {
    _cancelToken?.cancel();
  }

  /// Applies the staged desktop update and relaunches Lekis.
  Future<void> restartToUpdate() async {
    final staged = state.staged;
    if (staged == null || state.phase == AppUpdaterPhase.restarting) return;
    state = state.copyWith(phase: AppUpdaterPhase.restarting, clearError: true);
    try {
      await applyStagedDesktopUpdateAndRelaunch(staged);
    } catch (e) {
      state = state.copyWith(
        phase: AppUpdaterPhase.error,
        errorMessage: e.toString(),
      );
    }
  }
}

/// Triggers a quiet background update check on desktop platforms after startup.
void scheduleStartupUpdateCheck(ProviderContainer container) {
  if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
  Future<void>.delayed(const Duration(seconds: 5), () {
    container.read(appUpdaterProvider.notifier).checkForUpdates(silent: true);
  });
}
