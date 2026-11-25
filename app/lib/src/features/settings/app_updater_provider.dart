// 应用在线更新状态机（Riverpod）。
//
// 桌面端参考 yetone/magpie：后台静默检查 → 发现新版本 → 应用内流式下载（带进度与速度）
// → SHA-256 校验 → 解压暂存 → 一键重启替换并自动拉起新版。
// 移动端或只读安装目录自动回退为直接打开下载链接。

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/desktop_tray/desktop_tray_controller.dart';
import '../../rust/api/core.dart' as core;
import 'app_updater.dart';
import 'desktop_self_updater.dart';

/// 记录上次自动检测更新的本地自然日（`YYYY-MM-DD`），每天最多静默检测一次。
const String kLastAutoUpdateCheckDayKey = 'ui.update.last_auto_check_day';

/// 将本地日期格式化为 `YYYY-MM-DD`。
String formatUpdateCheckDay(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

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
    this.promptPending = false,
  });

  final AppUpdaterPhase phase;
  final AppUpdateInfo? info;
  final UpdateDownloadProgress? progress;
  final StagedDesktopUpdate? staged;
  final SelfUpdateCapability? capability;
  final String? errorMessage;
  final String currentVersion;

  /// True when a background (silent) check found a release and the proactive
  /// prompt has not been handled yet. Manual checks from Settings open their
  /// own dialog, so they leave this false.
  final bool promptPending;

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
    bool? promptPending,
  }) => AppUpdaterState(
    phase: phase ?? this.phase,
    info: info ?? this.info,
    progress: clearProgress ? null : (progress ?? this.progress),
    staged: clearStaged ? null : (staged ?? this.staged),
    capability: capability ?? this.capability,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    currentVersion: currentVersion ?? this.currentVersion,
    promptPending: promptPending ?? this.promptPending,
  );
}

final appUpdaterProvider =
    NotifierProvider<AppUpdaterNotifier, AppUpdaterState>(
      AppUpdaterNotifier.new,
    );

class AppUpdaterNotifier extends Notifier<AppUpdaterState> {
  UpdateCancelToken? _cancelToken;
  DateTime? _lastCheckedAt;
  DateTime? _lastAutoErrorAt;
  String? _lastAutoCheckedDay;
  bool _dailyCheckInFlight = false;

  @override
  AppUpdaterState build() => const AppUpdaterState();

  /// 每天最多静默检查一次（按本地自然日持久化在核心设置中）。
  ///
  /// 启动时与每次进入「设置」页都会调用；当天已经成功检测过就直接跳过，
  /// 用户手动点「检查更新」仍走 [checkForUpdates] 不受此限制。
  Future<AppUpdateCheckResult?> checkOncePerDay({
    DateTime? now,
    bool allowInTests = false,
  }) async {
    if (_dailyCheckInFlight) return null;
    if (!allowInTests && Platform.environment['FLUTTER_TEST'] == 'true') {
      return null;
    }
    if (!(Platform.isAndroid ||
        Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux)) {
      return null;
    }
    final current = now ?? DateTime.now();
    final today = formatUpdateCheckDay(current);
    if (_lastAutoCheckedDay == today) return null;
    // 网络暂时不通时避免频繁重试，30 分钟内不重复发请求。
    if (_lastAutoErrorAt != null &&
        current.difference(_lastAutoErrorAt!) < const Duration(minutes: 30)) {
      return null;
    }

    _dailyCheckInFlight = true;
    try {
      try {
        final saved = await core.getSetting(key: kLastAutoUpdateCheckDayKey);
        if (saved == today) {
          _lastAutoCheckedDay = today;
          return null;
        }
      } catch (_) {
        // 测试环境或核心未就绪时退化为单次会话去重。
      }

      final result = await checkForUpdates(silent: true, bypassThrottle: true);
      if (result is AppUpdateUpToDate || result is AppUpdateAvailable) {
        _lastAutoCheckedDay = today;
        _lastAutoErrorAt = null;
        try {
          await core.setSetting(key: kLastAutoUpdateCheckDayKey, value: today);
        } catch (_) {}
      } else if (result is AppUpdateError) {
        _lastAutoErrorAt = current;
      }
      return result;
    } finally {
      _dailyCheckInFlight = false;
    }
  }

  /// Checks GitHub Releases for a newer version.
  ///
  /// When [silent] is true (e.g. startup or daily settings check), errors and
  /// up-to-date states do not disturb the user.
  Future<AppUpdateCheckResult?> checkForUpdates({
    bool silent = false,
    bool bypassThrottle = false,
  }) async {
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
        !bypassThrottle &&
        _lastCheckedAt != null &&
        DateTime.now().difference(_lastCheckedAt!) < const Duration(hours: 6)) {
      return null;
    }

    if (!silent) {
      state = state.copyWith(phase: AppUpdaterPhase.checking, clearError: true);
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
            promptPending: false,
          );
        }
      case AppUpdateError(:final message):
        if (!silent) {
          state = state.copyWith(
            phase: AppUpdaterPhase.error,
            errorMessage: message,
            promptPending: false,
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
            promptPending: false,
          );
        } else {
          state = state.copyWith(
            phase: AppUpdaterPhase.available,
            info: info,
            capability: capability,
            clearProgress: true,
            clearStaged: true,
            clearError: true,
            promptPending: silent,
          );
        }
    }
    return result;
  }

  /// Marks the proactive prompt as handled (shown, ignored, or deferred for
  /// this session) so it does not reopen on every state change.
  void clearPromptPending() {
    if (!state.promptPending) return;
    state = state.copyWith(promptPending: false);
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
      // The helper waits for this process to disappear before replacing files.
      await applyStagedDesktopUpdateAndRelaunch(staged, exitProcess: false);
      // exit(0) tears the process down while the native window is still alive;
      // on Windows that crashed cnativeapi.dll before the helper could run.
      // Close the window like the tray "Quit" item so Flutter and the native
      // window manager shut down cleanly.
      await ref.read(desktopTrayControllerProvider).quitApp();
    } catch (e) {
      state = state.copyWith(
        phase: AppUpdaterPhase.error,
        errorMessage: e.toString(),
      );
    }
  }
}

/// Triggers a quiet background update check after startup on every shipped
/// platform; the prompt host (see `update_prompt.dart`) decides whether to
/// interrupt the user.
void scheduleStartupUpdateCheck(ProviderContainer container) {
  if (!(Platform.isAndroid ||
      Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isLinux)) {
    return;
  }
  Future<void>.delayed(const Duration(seconds: 5), () {
    container.read(appUpdaterProvider.notifier).checkOncePerDay();
  });
}
