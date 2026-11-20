// 均衡器页面状态：读取 / 保存核心设置，滑杆变化做短节流后写回（PLY-04）。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';

/// 10 段中心频率（Hz），顺序必须和 Rust 侧一致。
const equalizerBandFrequenciesHz = <double>[
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

/// 频段数。
const equalizerBandCount = 10;

/// 增益下限（dB）。
const equalizerMinGainDb = -12.0;

/// 增益上限（dB）。
const equalizerMaxGainDb = 12.0;

/// 频段显示标签。
String equalizerBandLabel(int index) {
  final hz = equalizerBandFrequenciesHz[index];
  if (hz >= 1000) {
    final k = hz / 1000;
    return k == k.roundToDouble()
        ? '${k.round()}k'
        : '${k.toStringAsFixed(1)}k';
  }
  return hz.round().toString();
}

/// 可持久化的均衡器状态。
@immutable
class EqualizerState {
  const EqualizerState({
    required this.enabled,
    required this.preampDb,
    required this.bandsDb,
    required this.presets,
    this.presetId,
    this.saveError,
  });

  /// 从核心 DTO 映射；长度不足补 0，越界钳制，未知预设视为自定义。
  factory EqualizerState.fromDto(
    EqualizerDto dto,
    List<EqualizerPresetDto> presets,
  ) {
    final bands = List<double>.generate(equalizerBandCount, (index) {
      final value = index < dto.bandsDb.length ? dto.bandsDb[index] : 0.0;
      return _clamp(value);
    });
    final presetExists =
        dto.preset != null && presets.any((preset) => preset.id == dto.preset);
    return EqualizerState(
      enabled: dto.enabled,
      preampDb: _clamp(dto.preampDb),
      bandsDb: List<double>.unmodifiable(bands),
      presets: List<EqualizerPresetDto>.unmodifiable(presets),
      presetId: presetExists ? dto.preset : null,
    );
  }

  /// 是否启用。
  final bool enabled;

  /// 前级增益（dB）。
  final double preampDb;

  /// 10 段增益（dB）。
  final List<double> bandsDb;

  /// 内置预设。
  final List<EqualizerPresetDto> presets;

  /// 当前预设 ID；`null` = 自定义。
  final String? presetId;

  /// 最近一次保存失败（页面显示用）。
  final Object? saveError;

  /// 当前预设对象。
  EqualizerPresetDto? get currentPreset {
    final id = presetId;
    if (id == null) return null;
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// 是否完全平直。
  bool get isFlat =>
      preampDb.abs() < 0.001 && bandsDb.every((gain) => gain.abs() < 0.001);

  EqualizerState copyWith({
    bool? enabled,
    double? preampDb,
    List<double>? bandsDb,
    String? presetId,
    bool clearPreset = false,
    Object? saveError,
    bool clearSaveError = false,
  }) => EqualizerState(
    enabled: enabled ?? this.enabled,
    preampDb: preampDb ?? this.preampDb,
    bandsDb: bandsDb ?? this.bandsDb,
    presets: presets,
    presetId: clearPreset ? null : (presetId ?? this.presetId),
    saveError: clearSaveError ? null : (saveError ?? this.saveError),
  );

  /// 手动调整 preamp：视为自定义，不再显示旧预设。
  EqualizerState withPreamp(double value) => copyWith(
    preampDb: _clamp(value),
    clearPreset: true,
    clearSaveError: true,
  );

  /// 手动调整某一段：视为自定义。
  EqualizerState withBand(int index, double value) {
    if (index < 0 || index >= equalizerBandCount) return this;
    final bands = List<double>.of(bandsDb);
    bands[index] = _clamp(value);
    return copyWith(
      bandsDb: List<double>.unmodifiable(bands),
      clearPreset: true,
      clearSaveError: true,
    );
  }

  /// 应用一个内置预设（不自动改变启用开关）。
  EqualizerState withPreset(EqualizerPresetDto preset) {
    final bands = List<double>.generate(equalizerBandCount, (index) {
      final value = index < preset.bandsDb.length ? preset.bandsDb[index] : 0.0;
      return _clamp(value);
    });
    return copyWith(
      preampDb: _clamp(preset.preampDb),
      bandsDb: List<double>.unmodifiable(bands),
      presetId: preset.id,
      clearSaveError: true,
    );
  }

  /// 重置为平直曲线（保留启用开关）。
  EqualizerState flattened() => copyWith(
    preampDb: 0,
    bandsDb: List<double>.unmodifiable(
      List<double>.filled(equalizerBandCount, 0),
    ),
    clearPreset: true,
    clearSaveError: true,
  );

  EqualizerState withEnabled(bool value) =>
      copyWith(enabled: value, clearSaveError: true);

  EqualizerState withSaveError(Object? error) => error == null
      ? copyWith(clearSaveError: true)
      : copyWith(saveError: error);

  /// 转成 FFI DTO。
  EqualizerDto toDto() => EqualizerDto(
    enabled: enabled,
    preampDb: preampDb,
    bandsDb: Float32List.fromList(bandsDb),
    preset: presetId,
  );
}

double _clamp(double value) {
  if (value.isNaN) return 0;
  if (value < equalizerMinGainDb) return equalizerMinGainDb;
  if (value > equalizerMaxGainDb) return equalizerMaxGainDb;
  return value;
}

/// 核心读写入口；测试可覆盖这个 provider 注入假的资料库。
class EqualizerRepository {
  const EqualizerRepository();

  /// 读取设置和预设目录。
  Future<EqualizerState> load() async {
    final dto = await core.equalizer();
    final presets = core.equalizerPresets();
    return EqualizerState.fromDto(dto, presets);
  }

  /// 保存（Rust 侧还会再钳制一次）。
  Future<void> save(EqualizerState state) =>
      core.setEqualizer(settings: state.toDto());
}

/// 核心读写入口。
final equalizerRepositoryProvider = Provider<EqualizerRepository>(
  (ref) => const EqualizerRepository(),
);

/// 均衡器状态。
final equalizerProvider =
    AsyncNotifierProvider<EqualizerNotifier, EqualizerState>(
      EqualizerNotifier.new,
    );

/// 均衡器状态控制器：滑杆变化先更新界面，150 ms 没有新变化后再跨 FFI 保存。
class EqualizerNotifier extends AsyncNotifier<EqualizerState> {
  Timer? _debounce;
  bool _saving = false;
  bool _dirty = false;

  @override
  Future<EqualizerState> build() async {
    ref.onDispose(() => _debounce?.cancel());
    return ref.read(equalizerRepositoryProvider).load();
  }

  /// 重新从核心读取（加载失败后的重试）。
  Future<void> reload() async {
    state = const AsyncLoading<EqualizerState>();
    state = await AsyncValue.guard(
      () => ref.read(equalizerRepositoryProvider).load(),
    );
  }

  /// 启用 / 停用，立即保存。
  Future<void> setEnabled(bool enabled) async {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.withEnabled(enabled));
    await saveNow();
  }

  /// 修改 preamp，节流保存。
  void setPreamp(double value) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.withPreamp(value));
    _scheduleSave();
  }

  /// 修改某一段增益，节流保存。
  void setBand(int index, double value) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.withBand(index, value));
    _scheduleSave();
  }

  /// 应用预设，立即保存。
  Future<void> applyPreset(String presetId) async {
    final current = state.value;
    if (current == null) return;
    EqualizerPresetDto? selected;
    for (final preset in current.presets) {
      if (preset.id == presetId) {
        selected = preset;
        break;
      }
    }
    if (selected == null) return;
    state = AsyncData(current.withPreset(selected));
    await saveNow();
  }

  /// 重置为平直曲线，立即保存。
  Future<void> resetFlat() async {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.flattened());
    await saveNow();
  }

  /// 取消等待中的节流并立刻保存当前值。
  Future<void> saveNow() async {
    _debounce?.cancel();
    _debounce = null;
    await _save();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      _debounce = null;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    if (_saving) {
      _dirty = true;
      return;
    }
    _saving = true;
    try {
      do {
        _dirty = false;
        final current = state.value;
        if (current == null) return;
        try {
          await ref.read(equalizerRepositoryProvider).save(current);
          final latest = state.value;
          if (latest != null) {
            state = AsyncData(latest.withSaveError(null));
          }
        } catch (error) {
          final latest = state.value;
          if (latest != null) {
            state = AsyncData(latest.withSaveError(error));
          }
        }
      } while (_dirty);
    } finally {
      _saving = false;
    }
  }
}
