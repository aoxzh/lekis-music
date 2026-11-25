// 设置页的状态：输出设备 / 模式、存在核心里的开关、关于信息。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';

/// 核心设置项键名。
abstract final class SettingKeys {
  /// `true` / `false`，默认开。
  // TODO(core-gapless): 核心目前总是无缝播放、并不读取这个键；先存下用户的选择。
  static const gapless = 'playback.gapless';

  /// 交叉淡入淡出时长（毫秒，0 表示关闭，最大 12000）。
  static const crossfadeMs = 'playback.crossfade_ms';

  /// 交叉淡入淡出智能跳过尾声静音：`true`（默认）/ `false`。
  static const crossfadeSmartSilence = 'playback.crossfade_smart_silence';

  /// NAS / 远端流媒体播放缓存上限（MB，默认 2048，0 表示关闭）。
  static const streamCacheLimitMb = 'cache.stream_limit_mb';

  /// 扫描完成后自动合并跨源同一首歌：`true`（默认）/ `false`。
  static const unifiedAutoMerge = 'library.unified_auto_merge';

  /// `true` / `false`，默认开启。控制曲目菜单里的“观看视频”入口。
  static const video = 'video.enabled';

  /// `track`（默认）/ `album` / `off`，核心的 resolver 会读取。
  static const replayGain = 'playback.replaygain';

  /// 上次选择的输出设备 ID；空字符串表示跟随系统默认。
  static const outputDevice = 'playback.output_device';

  /// `shared` / `exclusive`。
  static const outputMode = 'playback.output_mode';

  /// 歌词视图样式：`classic`（默认）/ `flow` / `steps` / `tilt`。
  static const lyricsStage = 'ui.lyrics_stage';
  static const lyricsPresets = 'ui.lyrics_presets';

  /// 歌词舞台火花：`true`（默认）/ `false`。只对舞台样式有效。
  static const lyricsSparks = 'ui.lyrics_sparks';

  /// 注音歌词：`off`（默认）/ `plain` / `tone` / `tone_num`。
  /// 在汉字上方标拼音（UIX-11），经典视图生效。
  static const lyricsRuby = 'ui.lyrics_ruby';
  static const lyricsFontScale = 'ui.lyrics_font_scale';
  static const lyricsTranslation = 'ui.lyrics_translation';

  /// 播放页歌词浮层：默认都不显示（`true` 才显示）。
  static const lyricsDialButton = 'ui.lyrics_dial_button';
  static const lyricsSourceBadge = 'ui.lyrics_source_badge';
  static const lyricsOffsetBar = 'ui.lyrics_offset_bar';

  /// 补全结果写入音源目录：`false` 关闭；缺省开启。
  static const writeEnrichSidecars = 'enrich.write_sidecars';

  /// 旧补全结果迁移标记；核心完成后写 `done`。
  static const sidecarBackfill = 'enrich.sidecars_backfill';
}

enum ReplayGainMode {
  track('track'),
  album('album'),
  off('off');

  const ReplayGainMode(this.storageValue);
  final String storageValue;

  static ReplayGainMode fromStorage(String? v) =>
      values.firstWhere((m) => m.storageValue == v, orElse: () => track);
}

/// 一个字符串设置项（从核心读写）。值为 `null` 表示没设置过。
final settingProvider =
    AsyncNotifierProvider.family<SettingNotifier, String?, String>(
      SettingNotifier.new,
    );

class SettingNotifier extends AsyncNotifier<String?> {
  SettingNotifier(this.key);
  final String key;

  @override
  Future<String?> build() => core.getSetting(key: key);

  /// 先更新界面，再写核心；失败时回滚并抛出。
  Future<void> set(String value) async {
    final previous = state;
    state = AsyncData(value);
    try {
      await core.setSetting(key: key, value: value);
    } catch (e) {
      state = previous;
      rethrow;
    }
  }
}

@immutable
class PlaybackOutputState {
  const PlaybackOutputState({
    this.devices = const [],
    this.selectedDeviceId,
    this.mode = OutputModeDto.shared,
    this.error,
  });

  final List<OutputDeviceDto> devices;

  /// `null` = 跟随系统默认。
  final String? selectedDeviceId;
  final OutputModeDto mode;

  /// 列举设备失败时的核心错误。
  final Object? error;

  /// 当前实际使用的设备（选了默认时取系统默认设备）。
  OutputDeviceDto? get effectiveDevice {
    final id = selectedDeviceId;
    for (final d in devices) {
      if (id == null ? d.isDefault : d.id == id) return d;
    }
    return null;
  }

  bool get exclusiveSupported => effectiveDevice?.supportsExclusive ?? false;

  PlaybackOutputState copyWith({
    List<OutputDeviceDto>? devices,
    String? selectedDeviceId,
    bool clearSelected = false,
    OutputModeDto? mode,
    Object? error,
  }) => PlaybackOutputState(
    devices: devices ?? this.devices,
    selectedDeviceId: clearSelected
        ? null
        : (selectedDeviceId ?? this.selectedDeviceId),
    mode: mode ?? this.mode,
    error: error,
  );
}

/// 输出设备与输出模式。
final playbackOutputProvider =
    NotifierProvider<PlaybackOutputNotifier, PlaybackOutputState>(
      PlaybackOutputNotifier.new,
    );

class PlaybackOutputNotifier extends Notifier<PlaybackOutputState> {
  @override
  PlaybackOutputState build() => _read();

  PlaybackOutputState _read() {
    try {
      final snapshot = core.playbackSnapshot();
      return PlaybackOutputState(
        devices: core.listOutputDevices(),
        selectedDeviceId: snapshot.outputDevice,
        mode: snapshot.outputMode,
      );
    } catch (e) {
      return PlaybackOutputState(error: e);
    }
  }

  void refresh() => state = _read();

  /// 切换输出设备（`null` = 跟随系统）。失败时抛出核心错误。
  Future<void> selectDevice(String? id) async {
    core.setOutputDevice(deviceId: id);
    state = id == null
        ? state.copyWith(clearSelected: true)
        : state.copyWith(selectedDeviceId: id);
    // 新设备不支持独占时退回共享。Android 上独占就是 USB 直出，核心会忽略这个请求
    // 并返回仍在使用的模式（见 [setMode]），所以不会和 USB 开关矛盾。
    if (state.mode == OutputModeDto.exclusive && !state.exclusiveSupported) {
      await setMode(OutputModeDto.shared);
    }
    await core.setSetting(key: SettingKeys.outputDevice, value: id ?? '');
  }

  /// 切换输出模式。失败时抛出核心错误。
  ///
  /// 核心返回实际使用的模式（Android 上由 USB DAC 直出开关决定），界面以它为准；
  /// 请求被拒时不改写保存的设置。
  Future<void> setMode(OutputModeDto mode) async {
    final effective = core.setOutputMode(mode: mode);
    state = state.copyWith(mode: effective);
    if (effective != mode) return;
    await core.setSetting(key: SettingKeys.outputMode, value: mode.name);
  }

  /// 别处（USB DAC 直出开关）已经让核心换了模式：只同步界面。
  void adoptMode(OutputModeDto mode) {
    if (state.mode != mode) state = state.copyWith(mode: mode);
  }
}

/// 启动时把上次保存的输出设备 / 模式交回核心（由应用外壳在核心初始化后调用）。
/// 设备已经不存在时跟随系统默认。失败静默。
Future<void> restorePlaybackOutput() async {
  try {
    final deviceId = await core.getSetting(key: SettingKeys.outputDevice);
    final devices = core.listOutputDevices();
    final device = devices.where((d) => d.id == deviceId).firstOrNull;
    if (device != null) core.setOutputDevice(deviceId: device.id);
    final mode = await core.getSetting(key: SettingKeys.outputMode);
    if (mode == OutputModeDto.exclusive.name &&
        (device ?? devices.where((d) => d.isDefault).firstOrNull)
                ?.supportsExclusive ==
            true) {
      core.setOutputMode(mode: OutputModeDto.exclusive);
    }
  } catch (_) {}
}

@immutable
class AboutInfo {
  const AboutInfo({this.coreVersion, this.deviceId});
  final String? coreVersion;
  final String? deviceId;
}

final aboutInfoProvider = Provider<AboutInfo>((ref) {
  String? safe(String Function() f) {
    try {
      return f();
    } catch (_) {
      return null;
    }
  }

  return AboutInfo(
    coreVersion: safe(core.coreVersion),
    deviceId: safe(core.deviceId),
  );
});
